/**
 * CallPiP — Picture-in-Picture controller for the video call surface.
 *
 * When the user swipes home / switches apps during a video call, the remote
 * video XComponent transitions into a system-level floating PiP window instead
 * of freezing in the suspended app. The PiP window carries the standard
 * video-call controls (hang up, mic, camera, mute); taps are routed back into
 * CallService.
 *
 * Uses @ohos.PiPWindow (API 11+):
 *   - PiPWindow.isPiPEnabled()   — device/OS support check
 *   - PiPWindow.create(config)   — bind the remote XComponentController
 *   - controller.startPiP()      — enter the floating window
 *   - controller.on('controlPanelActionEvent', ...) — control buttons
 *
 * NOTE: PiP requires NO float-window permission — it is a system-managed
 * window (SYSTEM_FLOAT_WINDOW is only for window.TYPE_FLOAT).
 */
import { PiPWindow } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'CallPiP';
const DOMAIN = 0x0000;

export class CallPiP {
  private controller: PiPWindow.PiPController | null = null;
  private active: boolean = false;

  /** Handler callbacks the call surface wires in. */
  onHangUp: (() => void) | null = null;
  onMicToggle: ((on: boolean) => void) | null = null;
  onCameraToggle: ((on: boolean) => void) | null = null;
  onVoiceToggle: ((on: boolean) => void) | null = null;

  /**
   * Create (but do not start) the PiP controller bound to the remote video
   * XComponent's controller. Call once the XComponent is mounted.
   */
  async init(componentController: XComponentController, context: common.UIAbilityContext): Promise<boolean> {
    if (!PiPWindow.isPiPEnabled()) {
      hilog.warn(DOMAIN, TAG, 'PiP not enabled on this device');
      return false;
    }
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: componentController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_CALL,
        contentWidth: 540,
        contentHeight: 960,
      };
      const controller = await PiPWindow.create(config);
      this.controller = controller;
      // Auto-start PiP when the user returns home (swipe up / Home).
      controller.setAutoStartEnabled(true);
      this.registerControlEvents(controller);
      hilog.info(DOMAIN, TAG, 'PiP controller created');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'PiP create failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Enter the floating PiP window (e.g. on onPageHide / Home). */
  async startPiP(): Promise<void> {
    if (this.controller === null || this.active) {
      return;
    }
    try {
      await this.controller.startPiP();
      this.active = true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startPiP failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Leave the floating window (e.g. on call end). */
  async stopPiP(): Promise<void> {
    if (this.controller === null) {
      return;
    }
    try {
      await this.controller.stopPiP();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stopPiP failed: %{public}s', JSON.stringify(err));
    }
    this.active = false;
  }

  isActive(): boolean {
    return this.active;
  }

  private registerControlEvents(controller: PiPWindow.PiPController): void {
    controller.on('controlPanelActionEvent', (event: PiPWindow.PiPActionEventType, status?: number) => {
      hilog.info(DOMAIN, TAG, 'PiP control event: %{public}s status=%{public}d', event, status ?? -1);
      if (event === 'hangUp') {
        if (this.onHangUp !== null) {
          this.onHangUp();
        }
      } else if (event === 'micStateChanged') {
        if (this.onMicToggle !== null) {
          this.onMicToggle(status === PiPWindow.PiPControlStatus.OPEN);
        }
      } else if (event === 'videoStateChanged') {
        if (this.onCameraToggle !== null) {
          this.onCameraToggle(status === PiPWindow.PiPControlStatus.OPEN);
        }
      } else if (event === 'voiceStateChanged') {
        if (this.onVoiceToggle !== null) {
          this.onVoiceToggle(status === PiPWindow.PiPControlStatus.OPEN);
        }
      }
    });
  }
}

/** Singleton. */
export const callPiP = new CallPiP();
