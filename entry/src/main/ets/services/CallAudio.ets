/**
 * CallAudio — the pure-ArkTS audio half of the WhatsApp-native call spike.
 *
 * Mic capture (AudioCapturer → PCM s16le) and speaker playback
 * (AudioRenderer ← PCM s16le), relayed over a WebSocket to the backend
 * (which feeds whatsapp-rust's AudioSource/AudioSink channels).
 *
 * This is the low-risk half of Spike 2 and is fully ArkTS (no native code).
 * The H.264 video half requires the native C++ pipeline (see native/).
 *
 * Frame format: 48 kHz, stereo, s16le (matches the server's AudioSource
 * `Vec<i16>` + whatsapp-rust's PCM default).
 */
import { audio } from '@kit.AudioKit';
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'CallAudio';
const DOMAIN = 0x0000;

const SAMPLE_RATE = audio.AudioSamplingRate.SAMPLE_RATE_48000;
const CHANNELS = audio.AudioChannel.CHANNEL_2;
const CAPTURE_MS = 20; // 20ms frames → 1920 samples @48k stereo.

export class CallAudio {
  private capturer: audio.AudioCapturer | null = null;
  private renderer: audio.AudioRenderer | null = null;
  private ws: webSocket.WebSocket | null = null;
  private wsUrl: string = '';
  private running: boolean = false;
  private paused: boolean = false;
  private outputMuted: boolean = false;
  private frameBytes: number = 0;

  /** Configure the WS endpoint the audio frames ride over. */
  setWsUrl(url: string): void {
    this.wsUrl = url;
  }

  /**
   * Pause the call audio (incoming phone call / another app takes audio
   * focus). The renderer keeps its stream but no longer plays peer frames,
   * and the capturer stops sending mic frames so the two calls never overlap.
   */
  pause(): void {
    if (!this.running) {
      return;
    }
    this.paused = true;
    this.pcmQueue.length = 0;
  }

  /** Resume after the interruption ends. */
  resume(): void {
    if (!this.running) {
      return;
    }
    this.paused = false;
  }

  /** Mute the peer-audio output (PiP voice toggle). */
  setMuted(muted: boolean): void {
    this.outputMuted = muted;
    if (muted) {
      this.pcmQueue.length = 0;
    }
  }

  /** Whether the renderer should play peer frames (false while paused/muted). */
  isOutputEnabled(): boolean {
    return !this.paused && !this.outputMuted;
  }

  private ensureFrameSize(): void {
    // 48k * 2ch * 2 bytes * 20ms / 1000
    this.frameBytes = Math.floor(SAMPLE_RATE * 2 * 2 * CAPTURE_MS / 1000);
  }

  private openWs(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (this.ws !== null) {
        resolve(true);
        return;
      }
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
        if (err) {
          return;
        }
        // Incoming PCM frames from the peer → speaker (always binary).
        if (typeof data === 'string') {
          return;
        }
        this.playPcm(data);
      });
      ws.on('open', () => {
        resolve(true);
      });
      ws.on('error', () => {
        resolve(false);
      });
      ws.on('close', () => {
        this.ws = null;
      });
      ws.connect(this.wsUrl).catch(() => {
        resolve(false);
      });
    });
  }

  /** Start mic capture + WS relay. Call after granting MICROPHONE. */
  async start(): Promise<boolean> {
    if (this.running) {
      return true;
    }
    if (this.wsUrl.length === 0) {
      hilog.warn(DOMAIN, TAG, 'start: no ws url');
      return false;
    }
    if (!(await this.openWs())) {
      hilog.warn(DOMAIN, TAG, 'start: ws connect failed');
      return false;
    }
    this.ensureFrameSize();
    if (!(await this.startCapturer())) {
      return false;
    }
    if (!(await this.startRenderer())) {
      return false;
    }
    this.running = true;
    hilog.info(DOMAIN, TAG, 'call audio started');
    return true;
  }

  private startCapturer(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: SAMPLE_RATE,
        channels: CHANNELS,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      };
      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION,
        capturerFlags: 0,
      };
      const options: audio.AudioCapturerOptions = {
        streamInfo: streamInfo,
        capturerInfo: capturerInfo,
      };
      audio.createAudioCapturer(options).then((capturer: audio.AudioCapturer) => {
        this.capturer = capturer;
        capturer.on('readData', (buffer: ArrayBuffer) => {
          // Mic PCM frame → server (audio frames are binary WS messages).
          this.sendBinary(buffer);
        });
        capturer.start().then(() => {
          hilog.info(DOMAIN, TAG, 'capturer started');
          resolve(true);
        }).catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'capturer start failed: %{public}s', JSON.stringify(err));
          resolve(false);
        });
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'createAudioCapturer failed: %{public}s', JSON.stringify(err));
        resolve(false);
      });
    });
  }

  private startRenderer(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: SAMPLE_RATE,
        channels: CHANNELS,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      };
      const rendererInfo: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION,
        rendererFlags: 0,
      };
      const options: audio.AudioRendererOptions = {
        streamInfo: streamInfo,
        rendererInfo: rendererInfo,
      };
      audio.createAudioRenderer(options).then((renderer: audio.AudioRenderer) => {
        this.renderer = renderer;
        this.registerWriteData();
        this.registerInterruptListener();
        renderer.start().then(() => {
          hilog.info(DOMAIN, TAG, 'renderer started');
          resolve(true);
        }).catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'renderer start failed: %{public}s', JSON.stringify(err));
          resolve(false);
        });
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'createAudioRenderer failed: %{public}s', JSON.stringify(err));
        resolve(false);
      });
    });
  }

  /**
   * Audio-session priority: an incoming phone call (or another app taking
   * audio focus) interrupts our renderer. We pause the call audio so the two
   * streams never overlap; when the interruption ends we resume.
   */
  private registerInterruptListener(): void {
    if (this.renderer === null) {
      return;
    }
    try {
      this.renderer.on('audioInterrupt', (evt: audio.InterruptEvent) => {
        if (evt.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
          const hint = evt.hintType;
          if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
              hint === audio.InterruptHint.INTERRUPT_HINT_STOP ||
              hint === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
            this.pause();
          }
        } else {
          // INTERRUPT_TYPE_END → the other stream released the focus.
          this.resume();
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'audioInterrupt register failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Write an incoming PCM frame to the speaker. */
  private playPcm(buf: ArrayBuffer): void {
    if (this.renderer === null || !this.isOutputEnabled()) {
      return;
    }
    // Queue the frame; the writeData event drains it into the renderer's
    // provided buffer (the modern replacement for the deprecated write()).
    this.pcmQueue.push(new Uint8Array(buf));
  }

  private pcmQueue: Uint8Array[] = [];

  private registerWriteData(): void {
    if (this.renderer === null) {
      return;
    }
    try {
      this.renderer.on('writeData', (data: ArrayBuffer) => {
        const next = this.pcmQueue.shift();
        if (next !== undefined && data.byteLength >= next.byteLength) {
          new Uint8Array(data).set(next, 0);
          return audio.AudioDataCallbackResult.VALID;
        }
        return audio.AudioDataCallbackResult.INVALID;
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'writeData register failed: %{public}s', JSON.stringify(err));
    }
  }

  private sendBinary(buf: ArrayBuffer): void {
    if (this.ws === null) {
      return;
    }
    this.ws.send(buf).catch(() => {
      // frame dropped (transient)
    });
  }

  async stop(): Promise<void> {
    this.running = false;
    this.paused = false;
    this.outputMuted = false;
    this.pcmQueue.length = 0;
    try {
      await this.capturer?.stop();
      await this.capturer?.release();
    } catch (e) {
      // ignore
    }
    try {
      await this.renderer?.stop();
      await this.renderer?.release();
    } catch (e) {
      // ignore
    }
    this.capturer = null;
    this.renderer = null;
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (e) {
        // ignore
      }
      this.ws = null;
    }
    hilog.info(DOMAIN, TAG, 'call audio stopped');
  }
}

/** Singleton. */
export const callAudio = new CallAudio();
