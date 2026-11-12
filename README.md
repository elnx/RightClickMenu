# TukuRW

鸿蒙 PC 上的文件「就地读写」示例应用。在**文件管理**中对文件点右键 →「更多」→「TukuRW 就地加解密」，应用会拿到该文件的**真实文件 fd**，先备份到应用沙箱，再对原文件做 XOR 往返、`ftruncate` 改尺寸后写回、逐字节校验，最终保持原文件不变。

演示重点不是 XOR，而是这条通路：

```
fileContextMenu 右键 → want(uriList) → fileShare.persistPermission
  → fs.openSync(uri, READ_WRITE) 得到真实文件 fd
  → native(C++) 直接对 fd 做 pread / pwrite / ftruncate / fsync
```

适合作为「加解密引擎是 C++、只能吃 fd」这类应用的接入模板。也可以从桌面图标启动，用界面按钮对 PhotoPicker 选中的文件做同样的操作。

## 功能

- **右键菜单入口**：`fileContextMenu` 注册，系统下发 `menuHandler` + `uriList`
- **媒体 URI 打开**：`fs.openSync(uri, READ_WRITE)` 返回真实文件 fd，支持任意偏移读写、`truncate` 改尺寸、`fsync`
- **文件操作全在 native**：`fstat` / 读 / 备份 / XOR / `ftruncate` / 写回 / 复读校验，ArkTS 只负责 open/close 和日志
- **写前备份**：原文件先备份到应用沙箱（`files/backup.bin`），备份失败立即中止
- **授权持久化**：右键下发的临时 URI 授权通过 `FILE_ACCESS_PERSIST` 持久化，应用启动时 `activatePermission` 恢复
- **冷/热启动一致**：应用已在运行时再次右键，`onNewWant` 通过 `eventHub` 通知页面重新读取 want
- **日志**：界面日志区 + 沙箱 `files/tukurw.log` + hilog（tag `TukuRW`）

## 环境要求

- DevEco Studio 5.0.1 及以上
- HarmonyOS SDK API 13（5.0.1）
- 目标设备：HarmonyOS PC / 2in1（右键菜单只在文件管理器中生效）

## 用 DevEco Studio 构建与运行

1. **File → Open** 选择工程根目录，等待 Sync 完成。
2. **File → Project Structure → Signing Configs**，勾选 **Automatically generate signature**（需登录华为账号）。
   > 工程声明了两个受限权限 `ohos.permission.READ_IMAGEVIDEO` / `ohos.permission.WRITE_IMAGEVIDEO`。如果签名 profile 中没有对应 ACL，安装会被系统拒绝。仅使用右键/打开方式入口时不需要这两个权限，可从 `entry/src/main/module.json5` 删除后重新签名；`FILE_ACCESS_PERSIST`、`MEDIA_LOCATION` 为 normal 权限，安装即授予。
3. 连接设备，选择 `entry` 模块，**Run**。

native 模块由 `entry/build-profile.json5` 中的 `externalNativeOptions` 自动编译，无需手工配置 CMake 或 NDK 路径。

## 使用

### 右键入口

文件管理 → 来源 → 图库 → 选中一个图片/视频 → 右键 → 更多 → **「TukuRW 就地加解密」**。

应用启动后对第一个文件执行往返自检：

1. 备份原文件到沙箱
2. XOR 加密 → 同 fd 复读校验
3. XOR 解密 → 校验内容回到备份值
4. `ftruncate(fd, 8)` 改尺寸 → 写回原尺寸全量内容 → 校验
5. 与沙箱备份逐字节比较

结束后文件内容和尺寸均与操作前一致。中途失败时可用界面上的「从备份恢复」。

### 应用内入口

从桌面图标启动后可使用：

| 按钮 | 作用 |
|---|---|
| 选择照片 | PhotoPicker 选择文件 |
| 权限检查 | 查看/申请 `READ_IMAGEVIDEO`、`WRITE_IMAGEVIDEO`、`MEDIA_LOCATION` |
| 读取信息 | `fstat` 真实文件属性 |
| 一键自检 | 备份 → XOR 往返 → 改尺寸写回 → 逐字节校验 |
| 备份到沙箱 | 读 fd 写入 `files/backup.bin` 并 `fsync` |
| 就地 XOR 加密/解密 | 读全量 → XOR → `pwrite` 原偏移 → `fsync` → 复读校验 |
| 尺寸变化+全量回写 | `ftruncate` 缩小 → 恢复原尺寸 → 全量写回 → 校验 |
| 从备份恢复 | 用沙箱备份覆盖当前 fd |

右键拉起时，界面还会出现「右键文件」一组按钮，对 want 中的 URI 执行同样操作。

## 工作原理

### 1. 右键菜单注册

`entry/src/main/module.json5`：

```json5
"fileContextMenu": "$profile:menu"
```

`entry/src/main/resources/base/profile/menu.json`：

```json
{
  "fileContextMenu": [{
    "abilityName": "EntryAbility",
    "menuItem": "$string:menu_item_xor",
    "menuHandler": "tukurw_xor",
    "menuContext": [{ "menuKind": 1, "menuRule": "single", "fileSupportType": ["*"] }]
  }]
}
```

`EntryAbility` 从 `want.parameters` 读取：

```ts
const handler = want.parameters['menuHandler'] as string;   // "tukurw_xor"
const uris = want.parameters['uriList'] as Array<string>;   // 媒体 URI 数组
```

`fileSupportType: ["*"]` 对文件管理器中的所有文件生效，因此 `uriList` 也可能是 `file://docs/...`；应用接受任意 `file://` URI，native 侧只关心 fd。

### 2. 打开文件

```ts
const f = fs.openSync(uri, fs.OpenMode.READ_WRITE);
```

媒体 URI（`file://media/Photo/<file_id>/<title>/<display_name>`）由媒体库 DataShare 解析，回传真实文件 fd。拿到 fd 后，C++ 侧可以直接用 POSIX syscall 操作同一个文件，不需要拼裸路径。

不要使用 `CREATE | TRUNC`，也不要把路径改写成 `/data/storage/el2/media/...` 后交给文件 API：那是 FUSE 视图，`ftruncate` 返回 `ENOSYS`，且 `O_TRUNC` 会截断真实文件。

### 3. native 接口

`entry/src/main/cpp/napi_init.cpp` 通过 NAPI 接收 ArkTS 传来的 fd：

| 函数 | 作用 |
|---|---|
| `fsStat(fd)` | `fstat` → size / mode / uid / gid |
| `fsRead(fd)` | 读全量 → 长度 / sum32 / 头部字节 |
| `fsBackup(fd, dstPath)` | 读 fd → 写沙箱文件 → `fsync` |
| `fsXor(fd, key)` | 读全量 → XOR → `pwrite` 回原偏移 → `fsync` → 同 fd 复读校验 |
| `fsTruncateRewrite(fd, len)` | `ftruncate` 缩小 → 恢复原尺寸 → 全量写回 → 校验 |
| `fsRestore(fd, srcPath)` | 读沙箱备份 → `ftruncate` 到备份尺寸 → 写回 → 校验 |
| `fsCompare(fd, srcPath)` | fd 当前内容与备份逐字节比较，报告首处差异 |

### 4. 安全约束

- 写前先备份到应用沙箱，备份失败即中止；
- 读-改-写全程使用同一个 `rw` fd，避免只读打开拿到脱敏视图后写回；
- 临时文件只写应用沙箱；
- 只处理用户显式交付的已有文件；新建或另存使用 `SaveButton` / `showAssetsCreationDialog`。

## 权限说明

| 权限 | 级别 | 用途 |
|---|---|---|
| `ohos.permission.READ_IMAGEVIDEO` | system_basic / user_grant（受限） | 通过 PhotoPicker 等入口读取图库文件 |
| `ohos.permission.WRITE_IMAGEVIDEO` | system_basic / user_grant（受限） | 就地写图库文件 |
| `ohos.permission.MEDIA_LOCATION` | normal / user_grant | 避免只读打开返回脱敏 EXIF |
| `ohos.permission.FILE_ACCESS_PERSIST` | normal / system_grant | 持久化右键下发的 URI 授权 |

`rw` 打开需要同时具备 `READ_IMAGEVIDEO` 和 `WRITE_IMAGEVIDEO`（AND 关系）。右键/打开方式给出的逐文件 URI 授权本身即可读写，**不依赖前两项受限权限**。

## 工程结构

```
AppScope/                                         应用配置与图标
build-profile.json5                               产品与 SDK 版本
entry/build-profile.json5                         native 构建配置
entry/src/main/module.json5                       权限、右键菜单注册
entry/src/main/resources/base/profile/menu.json   右键菜单项
entry/src/main/ets/entryability/EntryAbility.ets  入口 Ability，want 转发
entry/src/main/ets/pages/Index.ets                UI、URI → fd、授权持久化、日志
entry/src/main/cpp/napi_init.cpp                  fd 上的全部文件操作
entry/src/main/cpp/CMakeLists.txt                 native 构建脚本
```

## 排障

| 现象 | 原因 / 处置 |
|---|---|
| `13900001 EPERM` | 无权限，且该文件没有 URI 授权 |
| `13900012 EACCES` | 无权限直读 |
| `13900015 EEXIST` | 图库虚拟路径判定为「已存在」 |
| `13900019 EISDIR` | 传入的是目录 |
| `13900031 ENOSYS` | 走了裸路径/FUSE 视图 → 改用媒体 URI |
| 只读内容与磁盘不一致 | 缺 `MEDIA_LOCATION`，只读打开被脱敏 → 用 `rw` fd 读取 |
| 右键菜单不出现 | 只出现在文件管理的「更多」中；检查 `menuContext.menuKind` / `fileSupportType` |

## 已知限制

- 只支持已存在文件的就地读写；图库目录的创建、改名、删除、枚举任何权限都不支持；
- 云端未下载的资产不可用；
- 右键授权默认为临时授权，跨重启依赖 `FILE_ACCESS_PERSIST` 重新激活；
- XOR 仅用于演示 fd 通路，不构成加密方案。
