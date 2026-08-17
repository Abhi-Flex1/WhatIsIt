/**
 * SecurityBootBarrier — best-effort hardware attestation gate.
 *
 * When the device CAN attest (system-signed build with the ATTEST_KEY ACL),
 * this verifies the chain and blocks on a present-but-invalid chain. When
 * attestation is unavailable (normal debug install — the ATTEST_KEY
 * restricted permission can't be granted), the gate proceeds without
 * blocking so the app still runs; `isVerified()` honestly reports the
 * weaker state.
 *
 * Flow:
 *   1. Generate (or reuse) the TEE ECC key + fetch the attestation chain.
 *   2. Verify the chain locally (signatures, Huawei TEE marker, root CA).
 *   3. On success → verified; session may proceed.
 *   4. Chain present but INVALID → wipe + block (device tampered).
 *   5. Attestation unavailable (permission denied) → proceed unverified.
 */
import { deviceAttestationEngine } from './DeviceAttestation';
import { integrityValidator } from './IntegrityValidator';
import { secureCredentialStore } from './SecureCredentialStore';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SecurityBootBarrier';
const DOMAIN = 0x0000;

export class SecurityBootBarrier {
  private verified: boolean = false;

  /**
   * Run the hardware-integrity gate. Returns true unless a PRESENT chain
   * fails verification (tamper detected). Attestation unavailability
   * (permission denied on a debug install) proceeds unverified.
   */
  async runGate(): Promise<boolean> {
    if (this.verified) {
      return true;
    }
    try {
      const nonce = this.randomNonce();
      const chain = await deviceAttestationEngine.generateAttestedIdentityKey(nonce);
      if (chain === null || chain.length === 0) {
        // Attestation unavailable (no ATTEST_KEY ACL on this install, or TEE
        // refused) — degrade gracefully, do NOT block the app.
        hilog.warn(DOMAIN, TAG, 'attestation unavailable — continuing unverified');
        return true;
      }
      const ok = await integrityValidator.verifyDeviceChainLocally(chain);
      if (!ok) {
        hilog.warn(DOMAIN, TAG, 'integrity verification FAILED — running lockdown');
        await secureCredentialStore.wipeAll();
        return false;
      }
      this.verified = true;
      hilog.info(DOMAIN, TAG, 'hardware integrity gate PASSED');
      return true;
    } catch (err) {
      // Unexpected exception — treat like unavailability: proceed, don't
      // brick the app for a hardening nicety.
      hilog.warn(DOMAIN, TAG, 'boot barrier exception — continuing unverified: %{public}s', JSON.stringify(err));
      return true;
    }
  }

  isVerified(): boolean {
    return this.verified;
  }

  private randomNonce(): string {
    // 32 crypto-grade bytes from the system random source (not Math.random).
    try {
      const rand = cryptoFramework.createRandom();
      const blob = rand.generateRandomSync(32);
      const bytes = blob.data;
      let hex = '';
      for (let i = 0; i < bytes.length; i++) {
        hex += bytes[i].toString(16).padStart(2, '0');
      }
      return hex;
    } catch (err) {
      // Random source unavailable — fall back to a time-seeded value so the
      // gate still runs (the challenge is a freshness marker, not the secret).
      return 'boot-' + Date.now().toString(16) + '-fallback';
    }
  }
}

/** Singleton. */
export const securityBootBarrier = new SecurityBootBarrier();
