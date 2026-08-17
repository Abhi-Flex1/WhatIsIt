/**
 * CallSurfaceView — the native WhatsApp-call surface.
 *
 * Shows the remote party's H.264 video on an XComponent (the decoder
 * surface from the native call_media module), local camera in a small
 * PiP-style overlay, and drives call controls (mute/camera/end) through
 * CallService → the backend → whatsapp-rust. Audio flows through CallAudio
 * (AudioCapturer/AudioRenderer) over the same WS.
 *
 * No ArkWeb, no Jitsi — this is the WhatsApp-native call media path.
 */
import { callService } from '../services/CallService';
import { callAudio } from '../services/CallAudio';
import { callPiP } from '../services/CallPiP';
import { backgroundAudioAgent } from '../services/BackgroundAudioAgent';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'CallSurfaceView';
const DOMAIN = 0x0000;
const WHATSAPP_GREEN = '#00A884';

@Component
export struct CallSurfaceView {
  chatName: string = '';
  callId: string = '';
  isVideo: boolean = false;
  onClose: () => void = () => {};
  @State muted: boolean = false;
  @State cameraOn: boolean = true;
  @State callState: string = 'active';
  private remoteXComponentController: XComponentController = new XComponentController();
  private localXComponentController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'call surface open: %{public}s (video=%{public}s)', this.callId, this.isVideo);
    // Keep the VoIP audio alive through screen lock / app switch.
    const hostCtx = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      const uiCtx = hostCtx as common.UIAbilityContext;
      backgroundAudioAgent.init(uiCtx);
      backgroundAudioAgent.startContinuousVoipTask();
    }
    // Attach the remote decoder surface: the XComponent's surface id feeds the
    // native decoder, which renders peer video into it.
    if (this.isVideo) {
      this.startVideoPipeline();
      this.initPiP();
    }
    // Start audio pipeline (mic → WS → backend, peer audio ← WS → speaker).
    callAudio.setWsUrl(callService.getWsUrl());
    callAudio.start().catch(() => {
      hilog.warn(DOMAIN, TAG, 'call audio start failed');
    });
  }

  aboutToDisappear(): void {
    callAudio.stop();
    callPiP.stopPiP();
    backgroundAudioAgent.stopContinuousVoipTask();
  }

  /** App backgrounded (Home / app switch) → transition video into PiP. */
  onPageHide(): void {
    if (this.isVideo) {
      callPiP.startPiP();
    }
  }

  private startVideoPipeline(): void {
    // The remote XComponent surface id is available after the component mounts.
    const surfaceId = this.remoteXComponentController.getXComponentSurfaceId();
    if (surfaceId.length === 0) {
      hilog.warn(DOMAIN, TAG, 'remote XComponent surface not ready');
      return;
    }
    callService.startVideo(Number(surfaceId));
  }

  private initPiP(): void {
    callPiP.onHangUp = () => {
      this.end();
    };
    callPiP.onMicToggle = (on: boolean) => {
      this.muted = !on;
      callService.setMuted(this.muted);
    };
    callPiP.onCameraToggle = (on: boolean) => {
      this.cameraOn = on;
      callService.setCamera(on);
    };
    callPiP.onVoiceToggle = (on: boolean) => {
      callAudio.setMuted(!on);
    };
    const hostCtx = this.getUIContext().getHostContext();
    if (hostCtx !== undefined) {
      callPiP.init(this.remoteXComponentController, hostCtx as common.UIAbilityContext);
    }
  }

  private toggleMute(): void {
    this.muted = !this.muted;
    callService.setMuted(this.muted);
  }

  private toggleCamera(): void {
    this.cameraOn = !this.cameraOn;
    callService.setCamera(this.cameraOn);
  }

  private end(): void {
    callService.endCall();
    this.onClose();
  }

  build() {
    Stack() {
      // Remote video (decoder surface).
      XComponent({ id: 'remote', type: 'surface', controller: this.remoteXComponentController })
        .width('100%')
        .height('100%')
        .backgroundColor('#111B21')

      // Local camera preview (encoder surface) — small PiP-style overlay.
      if (this.isVideo && this.cameraOn) {
        XComponent({ id: 'local', type: 'surface', controller: this.localXComponentController })
          .width(120)
          .height(160)
          .borderRadius(12)
          .backgroundColor('#263238')
          .position({ x: 16, y: 16 })
      }

      // Top bar: back + honest label.
      Column() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor(['#FFFFFF'])
            .onClick(() => {
              this.end();
            })
          Column({ space: 2 }) {
            Text(this.chatName)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.callState + (this.isVideo ? ' · video' : ' · voice'))
              .fontSize(11)
              .fontColor('#E4E6EB')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor(WHATSAPP_GREEN)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // Bottom call controls.
      Row({ space: 24 }) {
        // Mute.
        Column({ space: 4 }) {
          SymbolGlyph(this.muted ? $r('sys.symbol.mic_slash') : $r('sys.symbol.mic'))
            .fontSize(24)
            .fontColor(['#FFFFFF'])
          Text('Mute')
            .fontSize(11)
            .fontColor('#E4E6EB')
        }
        .onClick(() => {
          this.toggleMute();
        })

        // Camera (video only).
        if (this.isVideo) {
          Column({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.video'))
              .fontSize(24)
              .fontColor([this.cameraOn ? '#FFFFFF' : '#FF5252'])
            Text('Camera')
              .fontSize(11)
              .fontColor('#E4E6EB')
          }
          .onClick(() => {
            this.toggleCamera();
          })
        }

        // End call.
        Column({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.phone'))
            .fontSize(26)
            .fontColor(['#FFFFFF'])
            .backgroundColor('#EA4335')
            .borderRadius(24)
            .padding(10)
          Text('End')
            .fontSize(11)
            .fontColor('#E4E6EB')
        }
        .onClick(() => {
          this.end();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 24 })
      .backgroundColor('#1F2C34')
      .position({ y: '88%' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111B21')
  }
}
