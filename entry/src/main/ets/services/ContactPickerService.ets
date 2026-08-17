import { contact } from '@kit.ContactsKit';
import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ContactPickerService';
const DOMAIN = 0x0000;

/** A lightweight address-book contact (only what WhatIsIt needs). */
export interface DeviceContact {
  key: string;
  name: string;
  phoneNumbers: string[];
}

/**
 * Address-book access for the in-app "New Chat" list.
 *
 * Fetches the device contacts into WhatIsIt's own list UI (no system picker).
 * READ_CONTACTS is requested at runtime only when the user opens the list.
 */
export class ContactPickerService {
  /** Request READ_CONTACTS at runtime if not already granted. */
  async ensureReadContacts(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const grant = await atManager.checkAccessToken(context.applicationInfo.accessTokenId,
        'ohos.permission.READ_CONTACTS' as Permissions);
      if (grant === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      const result = await atManager.requestPermissionsFromUser(context,
        ['ohos.permission.READ_CONTACTS'] as Permissions[]);
      const authResult = result.authResults;
      if (authResult !== undefined && authResult.length > 0 &&
        authResult[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      return false;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'ensureReadContacts failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** Fetch every address-book contact that has at least one phone number. */
  async fetchContacts(context: common.UIAbilityContext): Promise<DeviceContact[]> {
    const list: DeviceContact[] = [];
    try {
      const contacts = await contact.queryContacts(context);
      if (contacts === undefined) {
        return list;
      }
      for (const c of contacts) {
        if (c.phoneNumbers === undefined || c.phoneNumbers.length === 0) {
          continue;
        }
        const nums: string[] = [];
        for (const p of c.phoneNumbers) {
          if (p.phoneNumber !== undefined && p.phoneNumber.length > 0) {
            nums.push(ContactPickerService.normalizeE164(p.phoneNumber));
          }
        }
        if (nums.length === 0) {
          continue;
        }
        const full = c.name?.fullName;
        const name = full !== undefined && full.length > 0 ? full : 'Unknown';
        list.push({
          key: c.key !== undefined ? c.key : '',
          name: name,
          phoneNumbers: nums,
        });
      }
      list.sort((a: DeviceContact, b: DeviceContact) => {
        const an = a.name.toLowerCase();
        const bn = b.name.toLowerCase();
        return an < bn ? -1 : an > bn ? 1 : 0;
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'fetchContacts failed: %{public}s', JSON.stringify(err));
    }
    return list;
  }

  /** Strip spaces/dashes/parens/+; return digits only. */
  private static normalizeE164(raw: string): string {
    let out = '';
    for (let i = 0; i < raw.length; i++) {
      const ch = raw[i];
      if (ch >= '0' && ch <= '9') {
        out += ch;
      }
    }
    return out;
  }

  /** Build a WhatsApp user JID from an E.164 digit string. */
  static toWhatsAppJid(digits: string): string {
    return digits + '@s.whatsapp.net';
  }

  /** "John Smith" → "JS" (up to two initials, uppercase). */
  static initials(name: string): string {
    const parts = name.trim().split(' ');
    if (parts.length === 0 || parts[0].length === 0) {
      return '?';
    }
    const a = parts[0].charAt(0);
    if (parts.length > 1 && parts[1].length > 0) {
      return (a + parts[1].charAt(0)).toUpperCase();
    }
    return a.toUpperCase();
  }
}

export const contactPicker = new ContactPickerService();