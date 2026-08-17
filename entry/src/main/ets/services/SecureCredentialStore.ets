/**
 * SecureCredentialStore — hardware-backed session credential storage.
 *
 * Uses the Asset Store Kit (@ohos.security.asset) to hold the backend session
 * token / meowcaller identity so it never sits in plaintext config files.
 * Access is gated on the device unlock state (DEVICE_UNLOCKED), tying the
 * credential to the hardware lock state.
 *
 * Real API surface (API 24):
 *   - asset.add(attributes: AssetMap)          → Promise<void>
 *   - asset.remove(query: AssetMap)            → Promise<void>
 *   - AssetMap = Map<Tag, Value>; Value = boolean | number | Uint8Array
 *     (no AssetAttributes class exists — the sketch fabricated it)
 *   - asset.Tag.{SECRET, ALIAS, ACCESSIBILITY, IS_PERSISTENT}
 *   - asset.Accessibility.DEVICE_UNLOCKED
 *
 * NOTE: Tag.IS_PERSISTENT requires ohos.permission.STORE_PERSISTENT_DATA
 * (system_grant restricted). The store still works without it; persistence
 * just falls back to per-install lifetime.
 */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'SecureCredentialStore';
const DOMAIN = 0x0000;

const SESSION_ALIAS = 'whatisit_session_token';

export class SecureCredentialStore {
  /** Store the backend session token in the hardware-backed asset store. */
  async storeSessionToken(sessionToken: string): Promise<boolean> {
    const encoder = new util.TextEncoder();
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attr.set(asset.Tag.SECRET, encoder.encodeInto(sessionToken));
    attr.set(asset.Tag.ALIAS, encoder.encodeInto(SESSION_ALIAS));
    // Persist across app upgrades (requires STORE_PERSISTENT_DATA; ignored if not granted).
    attr.set(asset.Tag.IS_PERSISTENT, true);
    try {
      await asset.add(attr);
      hilog.info(DOMAIN, TAG, 'session credential locked in hardware asset store');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'asset store save failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Remove the session credential (normal logout / call end). */
  async clearSessionToken(): Promise<void> {
    const encoder = new util.TextEncoder();
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, encoder.encodeInto(SESSION_ALIAS));
    try {
      await asset.remove(query);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'asset store clear failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Lockdown: wipe every Asset Store entry this app owns. Called when the
   * hardware-attestation barrier fails (rooted / re-signed / compromised) so
   * no session credential or identity survives on the device.
   */
  async wipeAll(): Promise<void> {
    try {
      // A query with only ALIAS = '' removes all assets owned by this app.
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(''));
      await asset.remove(query);
      hilog.warn(DOMAIN, TAG, 'LOCKDOWN: asset store wiped (integrity breach)');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'asset wipe failed: %{public}s', JSON.stringify(err));
    }
  }
}

/** Singleton. */
export const secureCredentialStore = new SecureCredentialStore();
