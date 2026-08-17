/**
 * PasskeyService — orchestrates WhatsApp's SHORTCAKE passkey verification
 * during device linking.
 *
 * The Rust backend (whatsapp-rust v0.7.0) drives the passkey handshake; when
 * WhatsApp requires a WebAuthn assertion, the server broadcasts a
 * `passkey_request` WS event carrying `PublicKeyCredentialRequestOptions` JSON
 * and waits for the app to POST the assertion back.
 *
 * HarmonyOS passkey support: this SDK version has no Credential Manager /
 * WebAuthn API (only biometric `userIAM.userAuth`), so the service exposes the
 * raw assertion JSON for a developer/off-device flow (e.g. pasting an
 * assertion produced by a real authenticator). The moment `@kit` ships a
 * WebAuthn API, `obtainAssertion()` is the single place to swap in a native
 * `navigator.credentials.get`-style call.
 */
import { cdpBridge } from './CdpBridge';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'PasskeyService';
const DOMAIN = 0x0000;

/** Current state of a passkey ceremony. */
export class PasskeyState {
  /** Verbatim PublicKeyCredentialRequestOptions JSON from the server. */
  requestOptionsJson: string = '';
  /** The 4x4 verification code to show on screen (fresh link). */
  verificationCode: string = '';
  /** Human-readable error, if the ceremony failed. */
  error: string = '';
  /** Whether a passkey request is waiting for our assertion. */
  pending: boolean = false;
  /** Whether a verification code is currently on screen. */
  awaitingConfirmation: boolean = false;
}

export class PasskeyService {
  private state: PasskeyState = new PasskeyState();
  private listeners: Array<(s: PasskeyState) => void> = [];
  private bound: boolean = false;

  getState(): PasskeyState {
    return this.state;
  }

  /** Register a UI listener; fires on every passkey state change. */
  addListener(listener: (s: PasskeyState) => void): void {
    this.listeners.push(listener);
  }

  private notify(): void {
    for (const l of this.listeners) {
      try {
        l(this.state);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'listener error: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** Subscribe to the bridge WS events once. */
  bind(): void {
    if (this.bound) {
      return;
    }
    this.bound = true;
    cdpBridge.addEventListener((evt) => {
      if (evt.type === 'passkey_request') {
        const options = evt.options === undefined ? '' : evt.options;
        this.state.requestOptionsJson = options;
        this.state.pending = options.length > 0;
        this.state.error = '';
        this.notify();
      } else if (evt.type === 'passkey_confirmation') {
        this.state.verificationCode = evt.code === undefined ? '' : evt.code;
        this.state.awaitingConfirmation = true;
        this.state.pending = false;
        this.notify();
      } else if (evt.type === 'passkey_error') {
        this.state.error = evt.error === undefined ? 'Passkey verification failed' : evt.error;
        this.state.pending = false;
        this.notify();
      }
    });
  }

  /** Poll the backend for a pending request (recovery if the WS event missed). */
  async refresh(): Promise<void> {
    const options = await cdpBridge.passkeyRequest();
    if (options.length > 0) {
      this.state.requestOptionsJson = options;
      this.state.pending = true;
      this.state.error = '';
      this.notify();
    }
  }

  /**
   * Submit a WebAuthn assertion. Both args are base64url (no padding):
   *  - assertionJsonB64Url: {id, rawId, type:"public-key",
   *    response:{clientDataJSON, authenticatorData, signature, userHandle}}
   *  - credentialIdB64Url: the credential rawId
   */
  async submitAssertion(assertionJsonB64Url: string, credentialIdB64Url: string): Promise<boolean> {
    if (assertionJsonB64Url.length === 0 || credentialIdB64Url.length === 0) {
      this.state.error = 'Assertion payload is incomplete';
      this.notify();
      return false;
    }
    const ok = await cdpBridge.passkeyAssertion(credentialIdB64Url, assertionJsonB64Url);
    if (ok) {
      this.state.pending = false;
      this.notify();
    } else {
      this.state.error = 'Server rejected the passkey assertion';
      this.notify();
    }
    return ok;
  }

  /** Confirm the verification code shown on the phone (fresh link). */
  async confirm(): Promise<boolean> {
    const ok = await cdpBridge.passkeyConfirm();
    if (ok) {
      this.state.awaitingConfirmation = false;
      this.state.verificationCode = '';
      this.notify();
    }
    return ok;
  }

  /** Cancel the pending ceremony (user backed out). */
  async cancel(): Promise<void> {
    await cdpBridge.passkeyCancel();
    this.state.pending = false;
    this.state.verificationCode = '';
    this.state.awaitingConfirmation = false;
    this.state.error = '';
    this.notify();
  }
}

/** Singleton. */
export const passkeyService = new PasskeyService();
