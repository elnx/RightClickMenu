import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0xD000003;

export default class EntryAbility extends UIAbility {
  private applyWant(want: Want): void {
    if (!want || !want.parameters) {
      return;
    }
    const uri = want.parameters['uri'] as string;
    if (uri && uri.length > 0) {
      AppStorage.setOrCreate<string>('tukurwUri', uri);
    }
    const auto = want.parameters['auto'] as string;
    if (auto === '1') {
      AppStorage.setOrCreate<boolean>('tukurwAuto', true);
    }
    // 右键菜单（fileContextMenu）拉起时携带的 want 参数，见 module.json5 的 fileContextMenu + profile/menu.json
    const handler = want.parameters['menuHandler'] as string;
    if (handler && handler.length > 0) {
      AppStorage.setOrCreate<string>('tukurwHandler', handler);
    }
    const rawList = want.parameters['uriList'];
    if (rawList !== undefined && rawList !== null) {
      const arr = rawList as Array<string>;
      if (arr && arr.length > 0) {
        AppStorage.setOrCreate<string>('tukurwUriList', arr.join('\n'));
        hilog.info(DOMAIN, 'TukuRW', 'want uriList len=%{public}d first=%{public}s', arr.length, arr[0]);
      }
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'TukuRW', 'setColorMode fail: %{public}s', JSON.stringify(err));
    }
    this.applyWant(want);
    hilog.info(DOMAIN, 'TukuRW', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyWant(want);
    // 页面已加载时不会重新走 aboutToAppear，用 eventHub 通知 Index 重新读取 want 参数
    this.context.eventHub.emit('tukurwWant');
    hilog.info(DOMAIN, 'TukuRW', 'Ability onNewWant');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err && err.code) {
        hilog.error(DOMAIN, 'TukuRW', 'loadContent fail: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'TukuRW', 'loadContent ok');
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'TukuRW', 'Ability onDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'TukuRW', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'TukuRW', 'Ability onBackground');
  }
}
