import { contact } from '@kit.ContactsKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ContactPickerService';
const DOMAIN = 0x0000;

/**
 * Privacy-first contact selection.
 *
 * Uses the system Contact Picker (ContactSelectionOptions), so the app never
 * holds READ_CONTACTS permission and never sees the user's address book — the
 * system-isolated UI returns exactly one selected phone number.
 */
export class ContactPickerService {
  /** Launch the system single-select contact picker; returns a normalized
   *  E.164 phone number, or null if the user cancels / nothing selected. */
  async pickSinglePhoneNumber(): Promise<string | null> {
    try {
      const options: contact.ContactSelectionOptions = {
        isMultiSelect: false,
      };
      const selected = await contact.selectContacts(options);
      if (selected === undefined || selected.length === 0) {
        return null;
      }
      const first = selected[0];
      if (first.phoneNumbers === undefined || first.phoneNumbers.length === 0) {
        return null;
      }
      const raw = first.phoneNumbers[0].phoneNumber;
      if (raw === undefined) {
        return null;
      }
      return ContactPickerService.normalizeE164(raw);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'contact picker failed: %{public}s', JSON.stringify(err));
      return null;
    }
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
}

export const contactPicker = new ContactPickerService();
