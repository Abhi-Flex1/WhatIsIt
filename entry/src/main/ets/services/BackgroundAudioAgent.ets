/**
 * BackgroundAudioAgent — keeps the VoIP call alive when the screen locks or
 * the user switches apps.
 *
 * Uses the Continuous Task (BackgroundMode.VOIP) so the kernel does not
 * suspend the meowcaller audio capture/playback threads or the media WS
 * socket while the call is active. The wantAgent brings the user back into
 * the call when they tap the ongoing-call notification.
 *
 * Audio-session priority (pausing on an incoming phone call) is handled in
 * CallAudio, which owns the AudioRenderer/AudioCapturer and their per-stream
 * 'interrupt' events.
 */
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'BackgroundAudioAgent';
const DOMAIN = 0x0000;

export class BackgroundAudioAgent {
  private context: common.UIAbilityContext | null = null;
  private continuousTaskId: number = -1;
  private running: boolean = false;

  /** Bind the agent to the ability context (once, from the call surface). */
  init(ctx: common.UIAbilityContext): void {
    if (this.context === null) {
      this.context = ctx;
    }
  }

  /**
   * Register the continuous VoIP background task. Call when the user answers
   * or originates a call — the audio stream stays live with the screen locked
   * and through app switches.
   */
  async startContinuousVoipTask(): Promise<boolean> {
    if (this.running || this.context === null) {
      return this.running;
    }
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name,
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      });
      // The string-array overload declares the continuous-task background modes
      // (must match the ability's backgroundModes in module.json5) and returns
      // a ContinuousTaskNotification carrying the continuousTaskId.
      const info = await backgroundTaskManager.startBackgroundRunning(
        this.context,
        ['voip'],
        agent,
      );
      this.continuousTaskId = info.continuousTaskId ?? -1;
      this.running = true;
      hilog.info(DOMAIN, TAG, 'VoIP background agent acquired (task=%{public}d)', this.continuousTaskId);
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Release the continuous task. Call when the call ends to save battery. */
  async stopContinuousVoipTask(): Promise<void> {
    if (!this.running || this.context === null) {
      return;
    }
    try {
      if (this.continuousTaskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(this.context, this.continuousTaskId);
      } else {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
    this.running = false;
    this.continuousTaskId = -1;
    hilog.info(DOMAIN, TAG, 'VoIP background agent released');
  }

  /**
   * Audio-session priority is handled in CallAudio via the renderer's
   * per-stream 'interrupt' event (the audio manager has no 'audioInterrupt'
   * listener on this SDK level).
   */
  isRunning(): boolean {
    return this.running;
  }
}

/** Singleton. */
export const backgroundAudioAgent = new BackgroundAudioAgent();
