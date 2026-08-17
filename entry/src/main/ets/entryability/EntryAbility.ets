import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';
import { CdpBridge } from './../services/CdpBridge';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private provisioningHost: string = '';
  private provisioningPort: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.provisioningHost = '';
    this.provisioningPort = 0;
    const provision = CdpBridge.parseProvisionUrl(want.uri || '');
    if (provision !== null) {
      this.provisioningHost = provision.host;
      this.provisioningPort = provision.port;
      hilog.info(DOMAIN, 'testTag', 'provisioning from deep link: %{public}s:%{public}d', provision.host, provision.port);
      preferences.getPreferences(this.context, 'whatisit_cdp').then((prefs) => {
        prefs.put('provision_host', provision.host).catch(() => {});
        prefs.put('provision_port', String(provision.port)).catch(() => {});
        prefs.put('provision_pending', 'true').catch(() => {});
      }).catch(() => {});
    }
  }

  /** App Continuation: package the current chat/view into the migration want. */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    try {
      // Read the shell's current state (persisted on navigation) and carry it.
      const options: preferences.Options = { name: 'whatisit_cdp' };
      const store = preferences.getPreferencesSync(this.context, options);
      const chat = store.getSync('current_chat', '') as string;
      const view = store.getSync('current_view', '') as string;
      if (chat.length > 0) {
        wantParam['chatName'] = chat;
      }
      if (view.length > 0) {
        wantParam['view'] = view;
      }
      hilog.info(DOMAIN, 'testTag', 'onContinue: chat=%{public}s view=%{public}s', chat, view);
      return AbilityConstant.OnContinueResult.AGREE;
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'onContinue failed: %{public}s', JSON.stringify(err));
      return AbilityConstant.OnContinueResult.REJECT;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/MainPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}