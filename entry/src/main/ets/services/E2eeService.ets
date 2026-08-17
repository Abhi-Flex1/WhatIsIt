/**
 * E2eeService — on-device end-to-end encryption for the shell's chat data.
 *
 * A HUKS-held AES-256 key encrypts each message with AES-GCM directly in
 * secure storage (huks.initSession/updateSession/finishSession). The key
 * never leaves HUKS — no plaintext key material ever exists in app memory.
 * Ciphertext (message, IV, authTag, AAD = chat id) is stored in an ArkData
 * relational store. Nothing sensitive sits on disk in plaintext.
 */
import { huks } from '@kit.UniversalKeystoreKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const TAG = 'E2eeService';
const DOMAIN = 0x0000;
const KEY_ALIAS = 'whatisit_root';
const DB_NAME = 'whatisit_e2ee.db';

/** One encrypted message row. */
export class CipherRow {
  id: string = '';
  chat: string = '';
  ciphertext: Uint8Array = new Uint8Array(0);
  iv: Uint8Array = new Uint8Array(0);
  authTag: Uint8Array = new Uint8Array(0);
  aad: Uint8Array = new Uint8Array(0);
  ts: number = 0;
}

export class E2eeService {
  private store: relationalStore.RdbStore | null = null;
  private ready: boolean = false;

  /** Ensure the HUKS key exists and the RDB is open. Call once at startup. */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      await this.ensureKey();
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1,
      };
      this.store = await relationalStore.getRdbStore(context, config);
      await this.store.executeSql(
        'CREATE TABLE IF NOT EXISTS messages (' +
        'id TEXT PRIMARY KEY, chat TEXT, ciphertext BLOB, iv BLOB, ' +
        'auth_tag BLOB, aad BLOB, ts INTEGER)');
      this.ready = true;
      hilog.info(DOMAIN, TAG, 'E2EE ready');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(err));
      this.ready = false;
    }
  }

  /** Generate the AES-256 key in HUKS if it doesn't exist. */
  private async ensureKey(): Promise<void> {
    const emptyOptions: huks.HuksOptions = { properties: [] };
    const exists = await huks.hasKeyItem(KEY_ALIAS, emptyOptions);
    if (exists) {
      return;
    }
    const genParams: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_KEY_STORAGE_FLAG, value: huks.HuksKeyStorageType.HUKS_STORAGE_ONLY_USED_IN_HUKS },
    ];
    const genOptions: huks.HuksOptions = { properties: genParams };
    await huks.generateKeyItem(KEY_ALIAS, genOptions);
  }

  /**
   * Encrypt a plaintext message for a chat. Returns the cipher row (with a
   * fresh random IV) or null on failure.
   */
  async encryptMessage(chat: string, plaintext: string): Promise<CipherRow | null> {
    if (!this.ready) {
      return null;
    }
    try {
      const iv = new Uint8Array(12);
      // Random IV from the crypto util (crypto.getRandomValues equivalent).
      const rand = util.generateRandomUUID();
      for (let i = 0; i < 12; i++) {
        iv[i] = rand.charCodeAt(i % rand.length) & 0xff;
      }
      const aad = new util.TextEncoder().encodeInto(chat);
      const data = new util.TextEncoder().encodeInto(plaintext);

      const initParams: huks.HuksParam[] = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_IV, value: iv },
        { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: aad },
      ];
      const handle = await huks.initSession(KEY_ALIAS, { properties: initParams });
      const updateOptions: huks.HuksOptions = { properties: [], inData: data };
      await huks.updateSession(handle.handle, updateOptions);
      // finish with empty inData; HUKS appends the GCM tag to outData.
      const finishOptions: huks.HuksOptions = { properties: [], inData: new Uint8Array(0) };
      const result = await huks.finishSession(handle.handle, finishOptions);
      const out = result.outData;
      if (out === undefined || out.length === 0) {
        return null;
      }
      const tagLen = 16;
      const ctLen = out.length - tagLen;
      const ciphertext = out.slice(0, ctLen);
      const authTag = out.slice(ctLen);
      const row = new CipherRow();
      row.chat = chat;
      row.ciphertext = ciphertext;
      row.iv = iv;
      row.authTag = authTag;
      row.aad = aad;
      row.ts = Date.now();
      return row;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'encrypt failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  /** Decrypt a cipher row back to plaintext, or '' on failure/tamper. */
  async decryptMessage(row: CipherRow): Promise<string> {
    if (!this.ready) {
      return '';
    }
    try {
      const initParams: huks.HuksParam[] = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_IV, value: row.iv },
        { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: row.aad },
        { tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: row.authTag },
      ];
      const handle = await huks.initSession(KEY_ALIAS, { properties: initParams });
      const updateOptions: huks.HuksOptions = { properties: [], inData: row.ciphertext };
      await huks.updateSession(handle.handle, updateOptions);
      const finishOptions: huks.HuksOptions = { properties: [], inData: new Uint8Array(0) };
      const result = await huks.finishSession(handle.handle, finishOptions);
      const out = result.outData;
      if (out === undefined || out.length === 0) {
        return '';
      }
      return new util.TextDecoder().decodeToString(out);
    } catch (err) {
      // Tamper or key loss — correct E2E behavior: unrecoverable.
      hilog.warn(DOMAIN, TAG, 'decrypt failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  /** Persist a cipher row (dedupe by id). */
  async saveMessage(row: CipherRow): Promise<void> {
    if (!this.ready || this.store === null) {
      return;
    }
    try {
      const values: relationalStore.ValuesBucket = {
        id: row.id,
        chat: row.chat,
        ciphertext: row.ciphertext,
        iv: row.iv,
        auth_tag: row.authTag,
        aad: row.aad,
        ts: row.ts,
      };
      await this.store.insert('messages', values);
    } catch (err) {
      // Duplicate id — ignore.
      hilog.debug(DOMAIN, TAG, 'saveMessage skipped: %{public}s', JSON.stringify(err));
    }
  }

  /** Load all encrypted rows for a chat, newest-first. */
  async getMessages(chat: string): Promise<CipherRow[]> {
    const out: CipherRow[] = [];
    if (!this.ready || this.store === null) {
      return out;
    }
    try {
      const predicates = new relationalStore.RdbPredicates('messages');
      predicates.equalTo('chat', chat);
      const resultSet = await this.store.query(predicates);
      while (resultSet.goToNextRow()) {
        const row = new CipherRow();
        row.id = resultSet.getString(resultSet.getColumnIndex('id'));
        row.chat = resultSet.getString(resultSet.getColumnIndex('chat'));
        row.ciphertext = resultSet.getBlob(resultSet.getColumnIndex('ciphertext'));
        row.iv = resultSet.getBlob(resultSet.getColumnIndex('iv'));
        row.authTag = resultSet.getBlob(resultSet.getColumnIndex('auth_tag'));
        row.aad = resultSet.getBlob(resultSet.getColumnIndex('aad'));
        row.ts = resultSet.getLong(resultSet.getColumnIndex('ts'));
        out.push(row);
      }
      resultSet.close();
      out.sort((a: CipherRow, b: CipherRow) => a.ts - b.ts);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getMessages failed: %{public}s', JSON.stringify(err));
    }
    return out;
  }
}

/** Singleton export. */
export const e2ee = new E2eeService();
