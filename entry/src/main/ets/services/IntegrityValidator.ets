/**
 * IntegrityValidator — verifies the hardware attestation certificate chain
 * returned by DeviceAttestationEngine, locally, before the app opens any
 * session or renders the UI.
 *
 * Real API surface (API 24, @ohos.security.cert):
 *   - cert.createX509Cert(EncodingBlob) → Promise<X509Cert>
 *     EncodingBlob = { data: Uint8Array, encodingFormat: EncodingFormat }
 *   - X509Cert.verify(pubKey: cryptoFramework.PubKey) → Promise<void>
 *   - X509Cert.getPublicKey() → cryptoFramework.PubKey (synchronous)
 *   - X509Cert.getExtensionsObject() → CertExtension
 *   - CertExtension.getEntry(ExtensionEntryType, oid: DataBlob) → DataBlob
 *     (no string-OID getExtensionValue exists — the OID must be a DataBlob)
 *   - X509Cert.getSubjectName() / getIssuerName() → DataBlob
 *
 * Chain policy:
 *   1. Every cert parses as DER.
 *   2. Pairwise signature check: each cert is signed by the next one's public
 *      key (leaf ← intermediate ← root).
 *   3. The leaf must carry the Huawei attestation extension marker
 *      (1.3.6.1.4.1.2011.2.351) — present only on TEE-generated certs.
 *   4. The root's subject must match the embedded Huawei device root CA DN.
 */
import { cert } from '@kit.DeviceCertificateKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'IntegrityValidator';
const DOMAIN = 0x0000;

/** Huawei attestation extension OID carried in TEE-generated leaf certs. */
const HUAWEI_TEE_ATTESTATION_OID = '1.3.6.1.4.1.2011.2.351';
/** Embedded trust anchor: Huawei device root CA subject DN. */
const HW_ROOT_CA_SUBJECT = 'CN=Huawei Device Root CA';

/** OID string → DER-encoded dotted-decimal form (DataBlob for getEntry). */
function oidToDerBytes(oid: string): Uint8Array {
  const parts = oid.split('.').map((p) => Number(p));
  // First two arcs are encoded as 40*first + second.
  const bytes: number[] = [40 * parts[0] + parts[1]];
  for (let i = 2; i < parts.length; i++) {
    let v = parts[i];
    const stack: number[] = [];
    stack.push(v & 0x7f);
    v >>= 7;
    while (v > 0) {
      stack.push((v & 0x7f) | 0x80);
      v >>= 7;
    }
    for (let j = stack.length - 1; j >= 0; j--) {
      bytes.push(stack[j]);
    }
  }
  return new Uint8Array(bytes);
}

export class IntegrityValidator {
  /**
   * Verify the attestation chain structurally and check the Huawei TEE
   * attestation marker on the leaf. Returns true only if every step passes.
   */
  async verifyDeviceChainLocally(certChain: string[]): Promise<boolean> {
    if (certChain.length < 2) {
      hilog.warn(DOMAIN, TAG, 'chain too short: %{public}d', certChain.length);
      return false;
    }
    try {
      // 1. Parse all certs (the attestation returns base64 DER strings).
      const x509List: cert.X509Cert[] = [];
      const b64 = new util.Base64Helper();
      for (const b64cert of certChain) {
        const der = b64.decodeSync(b64cert);
        const x509 = await cert.createX509Cert({
          data: der,
          encodingFormat: cert.EncodingFormat.FORMAT_DER,
        });
        x509List.push(x509);
      }

      // 2. Pairwise signature verification: cert[i] signed by cert[i+1].
      for (let i = 0; i < x509List.length - 1; i++) {
        const signerKey = x509List[i + 1].getPublicKey();
        await x509List[i].verify(signerKey);
      }

      // 3. Leaf must carry the Huawei TEE attestation marker.
      const leaf = x509List[0];
      const extObj = leaf.getExtensionsObject();
      const oidBlob: cert.DataBlob = { data: oidToDerBytes(HUAWEI_TEE_ATTESTATION_OID) };
      const marker = extObj.getEntry(cert.ExtensionEntryType.EXTENSION_ENTRY_TYPE_ENTRY, oidBlob);
      if (marker === null || marker === undefined || marker.data.length === 0) {
        hilog.warn(DOMAIN, TAG, 'leaf missing Huawei TEE attestation extension');
        return false;
      }

      // 4. Root must be the embedded Huawei device root CA.
      const root = x509List[x509List.length - 1];
      const rootSubject = util.TextDecoder.create().decodeToString(root.getSubjectName().data);
      if (rootSubject.indexOf(HW_ROOT_CA_SUBJECT) < 0) {
        hilog.warn(DOMAIN, TAG, 'root subject mismatch: %{public}s', rootSubject);
        return false;
      }

      hilog.info(DOMAIN, TAG, 'attestation chain verified (root: %{public}s)', rootSubject);
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'chain validation failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }
}

/** Singleton. */
export const integrityValidator = new IntegrityValidator();
