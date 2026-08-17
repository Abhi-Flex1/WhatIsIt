/**
 * DeviceAttestationEngine — hardware-attested identity key.
 *
 * Generates an ECC-P256 key pair inside the secure TEE and requests a
 * hardware-backed certificate chain (attestation) for it. The chain resolves
 * to Huawei's hardware root CA and carries the device's boot-state /
 * security-level metadata. On a rooted or re-signed environment the
 * attestation either fails outright or the metadata discloses the
 * compromise, so the app can refuse to start.
 *
 * Real API surface (API 24, @ohos.security.huks):
 *   - huks.generateKeyItem(alias, HuksOptions)         → Promise<void>
 *   - huks.attestKeyItem(alias, HuksOptions)           → Promise<HuksReturnResult>
 *     (requires ohos.permission.ATTEST_KEY, system_grant restricted)
 *   - Result field is certChains (plural) — NOT certChain
 *   - Storage level enum: HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_DE
 *   - Digest: HuksKeyDigest.HUKS_DIGEST_SHA256
 */
import { huks } from '@kit.UniversalKeystoreKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'DeviceAttestation';
const DOMAIN = 0x0000;

export class DeviceAttestationEngine {
  private keyAlias: string = 'whatisit_hardware_root_identity';

  /**
   * Generate (or reuse) the hardware-tied ECC key and fetch its attestation
   * certificate chain. Returns the DER-encoded cert chain (leaf first) or
   * null if the hardware/attestation is unavailable or refused.
   */
  async generateAttestedIdentityKey(nonceChallenge: string): Promise<string[] | null> {
    const challengeBuffer = new util.TextEncoder().encodeInto(nonceChallenge);
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY,
      },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 },
      // Key lives at the device-level storage boundary (accessible after boot,
      // before first unlock) — inside the TEE key hierarchy.
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_DE },
      // Bind the attestation to a caller-supplied random challenge (replay protection).
      { tag: huks.HuksTag.HUKS_TAG_ATTESTATION_CHALLENGE, value: challengeBuffer },
    ];
    const options: huks.HuksOptions = { properties: properties };

    try {
      // Idempotent: if the key already exists, generateKeyItem fails with
      // 12000011 (key exists) — that's fine, we just reuse it.
      try {
        await huks.generateKeyItem(this.keyAlias, options);
      } catch (err) {
        const code = (err as BusinessError).code;
        if (code !== 12000011) {
          // Non-"exists" failure: report and abort attestation.
          hilog.warn(DOMAIN, TAG, 'generateKeyItem failed: %{public}s', JSON.stringify(err));
          return null;
        }
      }

      const certResult = await huks.attestKeyItem(this.keyAlias, options);
      const chain = certResult.certChains;
      if (chain === undefined || chain.length === 0) {
        hilog.warn(DOMAIN, TAG, 'attestKeyItem returned empty certChains');
        return null;
      }
      hilog.info(DOMAIN, TAG, 'attestation chain acquired (%{public}d certs)', chain.length);
      return chain;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'attestation aborted (TEE/root/env): %{public}s', JSON.stringify(err));
      return null;
    }
  }
}

/** Singleton. */
export const deviceAttestationEngine = new DeviceAttestationEngine();
