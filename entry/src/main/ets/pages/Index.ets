// TukuRW —— 图库文件「就地读写」最小可用应用（方案B：媒体 URI / DataShare fd）
//
// 核心事实：
//   fs.openSync("file://media/Photo/<file_id>/<title>/<name>", READ_WRITE)
//   → 媒体库 DataShare 扩展把「真实文件 fd」回传，因此支持：
//       read/write 任意偏移、truncate（尺寸可增可减）、fsync
//   权限：ohos.permission.READ_IMAGEVIDEO / WRITE_IMAGEVIDEO（受限权限，需 ACL+用户授权）
//         或该 file_id 上的逐文件授权（PhotoPicker 只给持久读；写需要写授权/受限权限）
//   注意：若缺 ohos.permission.MEDIA_LOCATION，只读打开会拿到「脱敏视图」（GPS 等 EXIF 被清零，
//         长度不变）；本应用一律用 READ_WRITE 打开，避免读到脱敏视图后被写回。
// 本版实现：ArkTS 只做三件事 —— fs.openSync(uri, READ_WRITE) 拿 fd / fs.closeSync 关 fd / 记日志；
//   拿到 fd 之后对该文件的一切操作（stat/read/变换/write/ftruncate/fsync/校验）全部在 native(C++)
//   里用 POSIX syscall 完成（entry/src/main/cpp/napi_init.cpp）。这正是"加解密库是 C++、只能吃 fd"
//   的落地方式：open 走官方推荐的 URI 通路拿到真实文件 fd，C++ 侧直接吃这个 fd。
import native from 'libentry.so';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri, fileShare } from '@kit.CoreFileKit';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';

const DOMAIN: number = 0xD000003;
const TAG: string = 'TukuRW';

const URI_PREFIX: string = 'file://media/';
const FILE_PREFIX: string = 'file://';           // media（图库）与 docs（文件管理器公共目录）通吃
const FUSE_BASE: string = '/data/storage/el2/media/';
const DEFAULT_KEY: number = 0x5A;

@Entry
@ComponentV2
struct Index {
  @Local logText: string = '';
  @Local uri: string = '';
  @Local keyHex: string = '5A';
  @Local cmUris: string[] = [];
  @Local cmHandler: string = '';
  @Local stateLine: string = 'idle';
  @Local sizeLine: string = 'size: -';
  @Local busy: boolean = false;
  private logFd: number = -1;
  private logFile: string = '';
  private backupFile: string = '';
  private backupDone: boolean = false;

  // EntryAbility.onNewWant → eventHub 事件回调（应用已在运行时再次右键/打开方式）
  private wantCb: () => void = () => {
    this.applyWantState();
  };

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.logFile = ctx.filesDir + '/tukurw.log';
    this.backupFile = ctx.filesDir + '/backup.bin';
    try {
      this.logFd = fs.openSync(this.logFile,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND).fd;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'open log fail %{public}d %{public}s', err.code, err.message);
    }
    this.log('# ===== TukuRW start pid=' + process.pid + ' log=' + this.logFile);
    ctx.eventHub.on('tukurwWant', this.wantCb);
    this.applyWantState();
    this.activatePersisted();
  }

  aboutToDisappear(): void {
    try {
      (getContext(this) as common.UIAbilityContext).eventHub.off('tukurwWant', this.wantCb);
    } catch (e) {
    }
  }

  // 读取 EntryAbility 写入 AppStorage 的 want 参数（冷启动 onCreate 与热启动 onNewWant 共用）
  private applyWantState(): void {
    const presetUri = AppStorage.get<string>('tukurwUri');
    if (presetUri && presetUri.length > 0) {
      this.uri = presetUri;
      this.log('PICK preset uri=' + presetUri);
    }
    if (AppStorage.get<boolean>('tukurwAuto') === true) {
      setTimeout(() => {
        this.fullTest();
      }, 2000);
    }
    const list = AppStorage.get<string>('tukurwUriList');
    const handler = AppStorage.get<string>('tukurwHandler');
    this.cmHandler = handler ? handler : '';
    if (list && list.length > 0) {
      this.cmUris = list.split('\n');
      this.log('CM 右键菜单拉起: menuHandler=' + this.cmHandler + ' 文件数=' + this.cmUris.length);
      for (const u of this.cmUris) {
        this.log('CM uri=' + u);
        this.logUriPathMapping(u);
      }
      this.uri = this.cmUris[0];
      this.persistCmUris();
      if (this.cmHandler === 'tukurw_xor') {
        this.log('CM 菜单项为「就地加解密」→ 1.5s 后对第一个文件跑「往返自检」(内容最终保持不变)');
        setTimeout(() => {
          this.cmRoundTrip(this.uri);
        }, 1500);
      }
      this.syncLog();
    }
  }

  // ---- FILE_ACCESS_PERSIST：把右键菜单给的临时 URI 授权持久化 ----
  private policyOf(u: string): fileShare.PolicyInfo {
    return {
      uri: u,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    };
  }

  private persistedListFile(): string {
    return (getContext(this) as common.UIAbilityContext).filesDir + '/persisted.txt';
  }

  // 读取去重后的持久化清单（文件不存在时返回空数组）
  private persistedUris(): string[] {
    let text = '';
    try {
      text = fs.readTextSync(this.persistedListFile());
    } catch (e) {
      return [];
    }
    const uris: string[] = [];
    for (const line of text.split('\n')) {
      if (line.length > 0 && !uris.includes(line)) {
        uris.push(line);
      }
    }
    return uris;
  }

  // 合并后 TRUNC 重写：同一 URI 反复右键不会让清单无限增长
  private savePersistedUris(uris: string[]): void {
    const all = this.persistedUris();
    for (const u of uris) {
      if (!all.includes(u)) {
        all.push(u);
      }
    }
    const f = fs.openSync(this.persistedListFile(),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, all.join('\n') + '\n');
    } finally {
      fs.closeSync(f);
    }
  }

  private async persistCmUris(): Promise<void> {
    if (this.cmUris.length === 0) {
      return;
    }
    const policies: fileShare.PolicyInfo[] = [];
    for (const u of this.cmUris) {
      policies.push(this.policyOf(u));
    }
    try {
      await fileShare.persistPermission(policies);
      this.log('PERSIST ok count=' + policies.length);
      try {
        this.savePersistedUris(this.cmUris);
      } catch (e) {
        this.log('PERSIST save list FAIL ' + this.errStr(e as BusinessError));
      }
    } catch (e) {
      this.log('PERSIST FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  // 应用重启后先 activate 再 open：验证"没有新的用户操作也能继续访问"
  private async activatePersisted(): Promise<void> {
    const uris = this.persistedUris();
    if (uris.length === 0) {
      return;
    }
    const policies: fileShare.PolicyInfo[] = [];
    for (const u of uris) {
      policies.push(this.policyOf(u));
    }
    try {
      await fileShare.activatePermission(policies);
      this.log('ACTIVATE ok count=' + policies.length + ' (无需新的用户操作)');
    } catch (e) {
      this.log('ACTIVATE FAIL ' + this.errStr(e as BusinessError));
      return;
    }
    for (const u of uris) {
      try {
        const f = fs.openSync(u, fs.OpenMode.READ_WRITE);
        this.log('ACTIVATE open ok ' + u + ' fd=' + f.fd);
        fs.closeSync(f);
      } catch (e) {
        this.log('ACTIVATE open FAIL ' + this.errStr(e as BusinessError) + ' ' + u);
      }
    }
    this.syncLog();
  }

  // 演示 URI 与沙箱内 FUSE 裸路径的互转（官方 API：@ohos.file.fileuri）
  private logUriPathMapping(u: string): void {
    try {
      const fu = new fileUri.FileUri(u);
      this.log('CM  -> FileUri.path(沙箱裸路径, 方案A)=' + fu.path);
      this.log('CM  -> getUriFromPath(该裸路径)=' + fileUri.getUriFromPath(fu.path));
      if (u.startsWith(URI_PREFIX)) {
        this.log('CM  -> 手工前缀映射 等价形式=file://media/' + u.substring(URI_PREFIX.length));
      }
    } catch (e) {
      this.log('CM  -> 路径转换失败 ' + this.errStr(e as BusinessError));
    }
  }

  // 右键入口的「就地加解密」往返自检：备份 → XOR → 校验已变 → XOR 还原 → 与备份逐字节比对
  private cmRoundTrip(u: string): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.stateLine = 'contextMenu roundTrip...';
    this.uri = u;
    this.log('');
    this.log('# ============ CM roundTrip (右键 → 就地加解密) ============');
    try {
      this.backupToSandbox();
    } catch (e) {
      this.log('CM BACKUP FAIL ' + this.errStr(e as BusinessError) + ' —— 中止(不改图库)');
      this.busy = false;
      this.stateLine = 'contextMenu roundTrip aborted';
      return;
    }
    this.xorInPlace('CM-XOR1(加密)');
    this.xorInPlace('CM-XOR2(解密还原)');
    this.verifyAgainstBackup();
    this.log('# ============ CM roundTrip done ============');
    this.stateLine = 'contextMenu roundTrip done';
    this.busy = false;
    this.syncLog();
  }

  // ---------------- logging ----------------
  private log(line: string): void {
    this.logText = this.logText + line + '\n';
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    if (this.logFd >= 0) {
      try {
        fs.writeSync(this.logFd, line + '\n');
      } catch (e) {
      }
    }
  }

  // native 返回的一行/多行日志：首行加前缀；t0>=0 时给末行补 " cost=…ms"
  private logNative(prefix: string, ret: string, t0: number): void {
    const lines = ret.split('\n');
    if (lines.length === 0 || lines[0].length === 0) {
      return;
    }
    lines[0] = prefix + lines[0];
    if (t0 >= 0) {
      lines[lines.length - 1] = lines[lines.length - 1] + ' cost=' + (Date.now() - t0) + 'ms';
    }
    this.logLines(lines.join('\n'));
  }

  private logLines(ret: string): void {
    for (const l of ret.split('\n')) {
      if (l.length > 0) {
        this.log(l);
      }
    }
  }

  private syncLog(): void {
    if (this.logFd >= 0) {
      try {
        fs.fsyncSync(this.logFd);
      } catch (e) {
      }
    }
    this.sizeLine = 'uri: ' + (this.uri.length > 0 ? this.uri : '(none)');
  }

  private xorKey(): number {
    let v = parseInt(this.keyHex, 16);
    if (isNaN(v) || v < 0 || v > 255) {
      return DEFAULT_KEY;
    }
    return v;
  }

  private errStr(err: BusinessError): string {
    return 'code=' + err.code + ' msg=' + err.message;
  }

  private requireUri(): boolean {
    if (!this.uri.startsWith(FILE_PREFIX)) {
      this.log('ERR 无可用文件 URI：请先点「1.选择照片」/右键菜单拉起，或用 aa start --ps uri <file://...> 预置');
      return false;
    }
    return true;
  }

  // ---------------- 1. 选择照片 / 权限 ----------------
  private async pickPhoto(): Promise<void> {
    try {
      const opt = new photoAccessHelper.PhotoSelectOptions();
      opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const picker = new photoAccessHelper.PhotoViewPicker();
      const res = await picker.select(opt);
      if (res.photoUris.length === 0) {
        this.log('PICK 用户取消，无 uri');
        return;
      }
      this.uri = res.photoUris[0];
      this.log('PICK uri=' + this.uri);
      this.log('PICK 对应裸路径(仅参考, 方案A)=' + FUSE_BASE + this.uri.substring(URI_PREFIX.length));
      this.syncLog();
    } catch (e) {
      this.log('PICK FAIL ' + this.errStr(e as BusinessError));
    }
  }

  private async checkPerms(): Promise<void> {
    const perms: Permissions[] = [
      'ohos.permission.READ_IMAGEVIDEO',
      'ohos.permission.WRITE_IMAGEVIDEO',
      'ohos.permission.MEDIA_LOCATION'
    ];
    let tokenId = 0;
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      tokenId = info.appInfo.accessTokenId;
      this.log('PERM bundle=' + info.name + ' tokenId=' + tokenId + ' uid=' + process.uid);
    } catch (e) {
      this.log('PERM bundleManager FAIL ' + this.errStr(e as BusinessError));
    }
    const at = abilityAccessCtrl.createAtManager();
    for (const p of perms) {
      try {
        const st = at.checkAccessTokenSync(tokenId, p);
        this.log('PERM check ' + p + ' => ' + st + (st === 0 ? ' (GRANTED)' : ' (DENIED)'));
      } catch (e) {
        this.log('PERM check ' + p + ' FAIL ' + this.errStr(e as BusinessError));
      }
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const res = await at.requestPermissionsFromUser(ctx, perms);
      for (let i = 0; i < res.permissions.length; i++) {
        this.log('PERM request ' + res.permissions[i] + ' authResult=' + res.authResults[i] +
          (res.authResults[i] === 0 ? ' (GRANTED)' : ' (DENIED)'));
      }
    } catch (e) {
      this.log('PERM requestFromUser FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  // ---------------- 2. 读取 / 备份（ArkTS 只开 fd，读写全在 native） ----------------
  private backupToSandbox(): void {
    const t0 = Date.now();
    const f = fs.openSync(this.uri, fs.OpenMode.READ_WRITE);
    try {
      this.logNative('', native.fsBackup(f.fd, this.backupFile), t0);
      this.backupDone = true;
    } finally {
      fs.closeSync(f);
    }
  }

  private openInfo(): void {
    if (!this.requireUri()) {
      return;
    }
    const t0 = Date.now();
    try {
      const f = fs.openSync(this.uri, fs.OpenMode.READ_WRITE);
      this.log('OPEN ok fd=' + f.fd + ' mode=READ_WRITE route=B(DataShare fd) → 后续操作 native(C++)');
      this.log(native.fsStat(f.fd));
      this.logNative('', native.fsRead(f.fd), t0);
      fs.closeSync(f);
    } catch (e) {
      this.log('OPEN/READ FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  // ---------------- 3. 就地改写（XOR 加解密演示） ----------------
  private xorInPlace(tag: string): void {
    if (!this.requireUri()) {
      return;
    }
    if (!this.backupDone) {
      this.log('WARN 尚未创建沙箱备份，自动备份中...');
      try {
        this.backupToSandbox();
      } catch (e) {
        this.log('BACKUP FAIL ' + this.errStr(e as BusinessError) + ' —— 已中止原地改写');
        return;
      }
    }
    const k = this.xorKey();
    const t0 = Date.now();
    try {
      const f = fs.openSync(this.uri, fs.OpenMode.READ_WRITE);
      try {
        this.logNative(tag + ' ', native.fsXor(f.fd, k), t0);
      } finally {
        fs.closeSync(f);
      }
      this.log('     (再点一次「xor」即可还原；XOR 是对合运算)');
    } catch (e) {
      this.log(tag + ' FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  // ---------------- 4. 尺寸变化后全量回写（内容保持不变；native ftruncate 可增可减） ----------------
  private rewriteInPlace(): void {
    if (!this.requireUri()) {
      return;
    }
    const t0 = Date.now();
    try {
      const f = fs.openSync(this.uri, fs.OpenMode.READ_WRITE);
      try {
        this.logNative('', native.fsTruncateRewrite(f.fd, 8), t0);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      this.log('REWRITE FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  // ---------------- 5. 从沙箱备份恢复 ----------------
  private restoreFromBackup(): void {
    if (!this.requireUri()) {
      return;
    }
    const t0 = Date.now();
    try {
      const f = fs.openSync(this.uri, fs.OpenMode.READ_WRITE);
      try {
        this.logNative('', native.fsRestore(f.fd, this.backupFile), t0);
        this.backupDone = true;
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      this.log('RESTORE FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  // ---------------- 6. 一键自检（数据保持不变） ----------------
  private async fullTest(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.requireUri()) {
      return;
    }
    this.busy = true;
    this.stateLine = 'fullTest running...';
    this.log('');
    this.log('# ============ fullTest @ ' + new Date().toISOString() + ' ============');
    await this.checkPerms();
    this.openInfo();
    try {
      this.backupToSandbox();
    } catch (e) {
      this.log('BACKUP FAIL ' + this.errStr(e as BusinessError) + ' —— 自检中止');
      this.busy = false;
      this.stateLine = 'fullTest aborted';
      return;
    }
    this.log('STEP xor(加密) —— 期望 sum 变化、VERIFY-OK');
    this.xorInPlace('STEP1');
    this.log('STEP xor(解密, 再点一次即还原) —— 期望 sum 回到备份值');
    this.xorInPlace('STEP2');
    this.log('STEP 尺寸变化测试(truncate→写回) —— 期望 CONTENT-IDENTICAL');
    this.rewriteInPlace();
    this.log('STEP 恢复校验 —— 与备份逐字节比较');
    this.verifyAgainstBackup();
    this.log('# ============ fullTest done ============');
    this.stateLine = 'fullTest done';
    this.busy = false;
    this.syncLog();
  }

  private verifyAgainstBackup(): void {
    if (!this.requireUri()) {
      return;
    }
    try {
      const f = fs.openSync(this.uri, fs.OpenMode.READ_ONLY);
      try {
        this.logLines(native.fsCompare(f.fd, this.backupFile));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      this.log('FINAL FAIL ' + this.errStr(e as BusinessError));
    }
    this.syncLog();
  }

  build() {
    Column() {
      Text('TukuRW —— 图库文件就地读写')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontFamily('HarmonyHeiTi')
        .margin({ top: 8, bottom: 4 })

      Text(this.stateLine)
        .fontSize(11)
        .fontFamily('HarmonyHeiTi')
        .width('100%')
        .constraintSize({ maxWidth: '640vp' })

      Text(this.sizeLine)
        .fontSize(10)
        .fontFamily('HarmonyHeiTi')
        .width('100%')
        .constraintSize({ maxWidth: '640vp' })
        .maxLines(2)

      Row() {
        Button('1.选择照片')
          .fontSize(13)
          .layoutWeight(1)
          .onClick(() => {
            this.pickPhoto();
          })
        Button('2.权限检查')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            this.checkPerms();
          })
        Button('3.读取信息')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            this.openInfo();
          })
        Button('4.一键自检')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 4 })
          .enabled(!this.busy)
          .onClick(() => {
            this.fullTest();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: '640vp' })
      .margin({ top: 6 })

      Row() {
        Button('备份到沙箱')
          .fontSize(13)
          .layoutWeight(1)
          .onClick(() => {
            if (this.requireUri()) {
              try {
                this.backupToSandbox();
              } catch (e) {
                this.log('BACKUP FAIL ' + this.errStr(e as BusinessError));
              }
              this.syncLog();
            }
          })
        Button('就地XOR加密/解密')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            this.xorInPlace('XOR');
          })
        Button('尺寸变化+全量回写')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            this.rewriteInPlace();
          })
        Button('从备份恢复')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            this.restoreFromBackup();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: '640vp' })
      .margin({ top: 4 })

      Row() {
        Text(this.cmUris.length > 0 ? ('右键: ' + this.cmUris[0]) : '右键: (未通过右键菜单拉起)')
          .fontSize(10)
          .fontFamily('HarmonyHeiTi')
          .layoutWeight(2)
          .maxLines(1)
        Button('右键文件:就地异或')
          .fontSize(12)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            if (this.cmUris.length > 0) {
              this.uri = this.cmUris[0];
              this.xorInPlace('CM-XOR');
            } else {
              this.log('ERR 未通过右键菜单拉起，无 uriList');
            }
          })
        Button('右键文件:往返自检')
          .fontSize(12)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            if (this.cmUris.length > 0) {
              this.cmRoundTrip(this.cmUris[0]);
            }
          })
        Button('右键文件:恢复')
          .fontSize(12)
          .layoutWeight(1)
          .margin({ left: 4 })
          .onClick(() => {
            if (this.cmUris.length > 0) {
              this.uri = this.cmUris[0];
              this.restoreFromBackup();
            }
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: '640vp' })
      .margin({ top: 4 })

      Row() {
        Text('XOR key(hex)')
          .fontSize(12)
          .fontFamily('HarmonyHeiTi')
        TextInput({ text: this.keyHex, placeholder: '5A' })
          .fontSize(12)
          .maxLength(4)
          .width(70)
          .margin({ left: 6 })
          .onChange((v: string) => {
            this.keyHex = v;
          })
        Button('清空日志')
          .fontSize(12)
          .margin({ left: 8 })
          .onClick(() => {
            this.logText = '';
          })
        Button('显示日志路径')
          .fontSize(12)
          .margin({ left: 8 })
          .onClick(() => {
            this.log('LOG logfile=' + this.logFile + ' backup=' + this.backupFile);
            this.syncLog();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: '640vp' })
      .margin({ top: 4 })

      TextArea({ text: this.logText, placeholder: '操作日志（同时写入应用沙箱 files/tukurw.log）' })
        .width('100%')
        .constraintSize({ maxWidth: '640vp' })
        .height(400)
        .fontSize(10)
        .fontFamily('HarmonyHeiTi')
        .margin({ top: 6 })
        .backgroundColor('#F2F2F2')
        .borderRadius(8)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10 })
  }
}
