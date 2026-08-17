/**
 * CallService — orchestrates a WhatsApp-native call (Spike 2 skeleton).
 *
 * Audio: CallAudio (pure ArkTS, AudioCapturer/AudioRenderer + WS relay).
 * Video: the native call_media module (H.264 encode/decode + XComponent
 * surfaces) — loaded dynamically; the project must have the native lib built.
 *
 * WS framing (matches the server's CallRelay channels):
 *   text   {type:"call_signal", callId, action, ...}   — signaling
 *   binary [tag:u8][payload]                            — media frames
 *        tag 1 = audio PCM, 2 = video AU
 */
import { callAudio } from './CallAudio';
import { cdpBridge } from './CdpBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

const TAG = 'CallService';
const DOMAIN = 0x0000;

declare const requireNapi: (name: string) => Object;

/** Typed surface for the native call_media NAPI module. */
interface CallMediaNative {
  initEncoder(width: number, height: number, bitrate: number): string;
  initDecoder(surfaceId: number): boolean;
  startEncoder(): void;
  startDecoder(): void;
  stopEncoder(): void;
  stopDecoder(): void;
  releaseEncoder(): void;
  releaseDecoder(): void;
  pushDecodedFrame(buf: ArrayBuffer): void;
  setEncodedCallback(cb: (data: ArrayBuffer) => void): void;
}

export class CallService {
  private ws: webSocket.WebSocket | null = null;
  private activeCallId: string = '';
  private native: Object | null = null;
  private videoOn: boolean = false;
  private cameraSurfaceId: string = '';
  private remoteSurfaceId: string = '';

  /** Start an outgoing call to a chat (JID) — signaling + media relay. */
  async startCall(chat: string, video: boolean): Promise<boolean> {
    // 1. Signaling: POST /call on the backend.
    const resp = await cdpBridge.callStart(chat, video);
    if (resp === null) {
      return false;
    }
    const callId = resp['callId'] as string;
    if (callId === undefined || callId.length === 0) {
      return false;
    }
    this.activeCallId = callId;
    // 2. Open the media WS.
    if (!(await this.openMediaWs())) {
      return false;
    }
    // 3. Audio pipeline.
    const wsUrl = cdpBridge.getWsUrl();
    callAudio.setWsUrl(wsUrl);
    if (!(await callAudio.start())) {
      hilog.warn(DOMAIN, TAG, 'audio start failed (call continues without mic)');
    }
    // 4. Video is started by the call surface (it provides the remote
    //    XComponent surface id via startVideo(remoteSurfaceId)).
    return true;
  }

  /** Accept an incoming call (callId from the WS incoming_call event). */
  async acceptCall(callId: string, video: boolean): Promise<boolean> {
    this.activeCallId = callId;
    const resp = await cdpBridge.callAccept(callId, video);
    if (resp === null) {
      return false;
    }
    if (!(await this.openMediaWs())) {
      return false;
    }
    callAudio.setWsUrl(cdpBridge.getWsUrl());
    await callAudio.start();
    return true;
  }

  async rejectCall(callId: string): Promise<boolean> {
    return cdpBridge.callReject(callId);
  }

  async endCall(): Promise<boolean> {
    if (this.activeCallId.length > 0) {
      await cdpBridge.callEnd(this.activeCallId);
      this.activeCallId = '';
    }
    await callAudio.stop();
    this.stopVideo();
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (e) {
        // ignore
      }
      this.ws = null;
    }
    return true;
  }

  /** The WS URL media frames ride over (matches the backend /ws). */
  getWsUrl(): string {
    return cdpBridge.getWsUrl();
  }

  /** The active call id (set by startCall/acceptCall). */
  getActiveCallId(): string {
    return this.activeCallId;
  }

  /** The camera input surface id (native encoder), if video started. */
  getCameraSurfaceId(): string {
    return this.cameraSurfaceId;
  }

  /** Mute/unmute the active call (backend → whatsapp-rust handle). */
  async setMuted(muted: boolean): Promise<boolean> {
    if (this.activeCallId.length === 0) {
      return false;
    }
    return cdpBridge.callMute(this.activeCallId, muted);
  }

  /** Toggle the camera on the active call. */
  async setCamera(on: boolean): Promise<boolean> {
    if (this.activeCallId.length === 0) {
      return false;
    }
    return cdpBridge.callCamera(this.activeCallId, on);
  }

  private openMediaWs(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (this.ws !== null) {
        resolve(true);
        return;
      }
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      ws.on('open', () => resolve(true));
      ws.on('error', () => resolve(false));
      ws.on('close', () => { this.ws = null; });
      ws.on('message', (_err: Object, data: string | ArrayBuffer) => {
        if (typeof data !== 'string') {
          // Binary media frame: [tag][payload] — video AUs to the decoder.
          const bytes = new Uint8Array(data as ArrayBuffer);
          if (bytes.length > 1 && bytes[0] === 2) {
            this.pushVideoFrame(bytes.subarray(1).buffer as ArrayBuffer);
          }
        }
      });
      ws.connect(cdpBridge.getWsUrl()).catch(() => resolve(false));
    });
  }

  // ---- video (native module) ----

  private loadNative(): Object | null {
    try {
      this.native = requireNapi('call_media');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'call_media native not loaded: %{public}s', JSON.stringify(err));
      this.native = null;
    }
    return this.native;
  }

  /** Init encoder+decoder; returns the camera surface id. */
  async startVideo(remoteSurfaceId: number): Promise<void> {
    const native = this.native as CallMediaNative | null;
    if (native === null) {
      hilog.warn(DOMAIN, TAG, 'video unavailable (native lib not built)');
      return;
    }
    try {
      // Encoder: returns the camera input surface id (the camera XComponent attaches it).
      this.cameraSurfaceId = native.initEncoder(640, 480, 1000000);
      // Decoder: feed the remote XComponent's surface id; returns success.
      native.initDecoder(remoteSurfaceId);
      this.remoteSurfaceId = remoteSurfaceId.toString();
      native.startEncoder();
      native.startDecoder();
      this.videoOn = true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startVideo failed: %{public}s', JSON.stringify(err));
    }
  }

  private pushVideoFrame(buf: ArrayBuffer): void {
    const native = this.native as CallMediaNative | null;
    if (native === null) {
      return;
    }
    try {
      native.pushDecodedFrame(buf);
    } catch (err) {
      // ignore
    }
  }

  private stopVideo(): void {
    const native = this.native as CallMediaNative | null;
    if (native !== null) {
      try {
        native.stopEncoder();
        native.stopDecoder();
        native.releaseEncoder();
        native.releaseDecoder();
      } catch (err) {
        // ignore
      }
    }
    this.native = null;
    this.videoOn = false;
  }
}

/** Singleton. */
export const callService = new CallService();
