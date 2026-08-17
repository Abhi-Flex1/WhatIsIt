import { ContactPickerService, contactPicker, DeviceContact } from '../services/ContactPickerService';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme } from '../styles/Theme';

const TAG = 'NewChatView';
const DOMAIN = 0x0000;

@Component
export struct NewChatView {
  onBack: () => void = () => {};
  onPick: (digits: string) => void = () => {};
  @State contacts: DeviceContact[] = [];
  @State filtered: DeviceContact[] = [];
  @State query: string = '';
  @State loading: boolean = true;
  @State denied: boolean = false;
  private picked: boolean = false;

  aboutToAppear(): void {
    this.loadContacts();
  }

  private async loadContacts(): Promise<void> {
    this.loading = true;
    hilog.info(DOMAIN, TAG, 'loadContacts: requesting READ_CONTACTS');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ok = await contactPicker.ensureReadContacts(ctx);
    hilog.info(DOMAIN, TAG, 'loadContacts: permission ok=%{public}s', ok.toString());
    if (!ok) {
      this.denied = true;
      this.loading = false;
      return;
    }
    this.denied = false;
    const list = await contactPicker.fetchContacts(ctx);
    hilog.info(DOMAIN, TAG, 'loadContacts: fetched %{public}d contacts', list.length);
    this.contacts = list;
    this.filtered = list;
    this.loading = false;
  }

  private onSearch(v: string): void {
    this.query = v;
    const q = v.trim().toLowerCase();
    if (q.length === 0) {
      this.filtered = this.contacts;
      return;
    }
    const out: DeviceContact[] = [];
    for (const c of this.contacts) {
      if (c.name.toLowerCase().includes(q)) {
        out.push(c);
        continue;
      }
      for (const n of c.phoneNumbers) {
        if (n.includes(v.trim())) {
          out.push(c);
          break;
        }
      }
    }
    this.filtered = out;
  }

  private pick(c: DeviceContact): void {
    if (this.picked) {
      return;
    }
    this.picked = true;
    if (c.phoneNumbers.length > 0) {
      this.onPick(c.phoneNumbers[0]);
    }
  }

  @Builder
  ContactRow(c: DeviceContact) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill($r('app.color.brand_soft'))
        Text(ContactPickerService.initials(c.name))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
      }
      .width(Theme.AVATAR_SIZE)
      .height(Theme.AVATAR_SIZE)

      Column({ space: 3 }) {
        Text(c.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
        if (c.phoneNumbers.length > 0) {
          Text(c.phoneNumbers[0])
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
            .maxLines(1)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(Theme.ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.surface'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      }
    })
    .onClick(() => {
      this.pick(c);
    })
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([$r('app.color.ink_subtle')])
          .width(40)
          .onClick(() => {
            this.onBack();
          })
        Text('New Chat')
          .fontSize(Theme.TYPE_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
          .margin({ left: 8 })
        Blank()
          .width(40)
      }
      .width('100%')
      .height(Theme.HEADER_HEIGHT)
      .padding({ left: 8, right: 12 })
      .backgroundColor($r('app.color.surface'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([$r('app.color.ink_faded')])
        TextInput({ placeholder: 'Search contacts', text: this.query })
          .layoutWeight(1)
          .height(38)
          .fontSize(16)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(Theme.RADIUS_FIELD)
          .onChange((v: string) => {
            this.onSearch(v);
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_page'))

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('app.color.brand'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
      } else if (this.denied) {
        Column({ space: 12 }) {
          Text('Contacts access needed')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text('Allow contacts access to pick who to chat with. You can change this in Settings any time.')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Button('Grant access')
            .height(44)
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.brand_text'))
            .borderRadius(Theme.RADIUS_PILL)
            .onClick(() => {
              this.loadContacts();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
      } else if (this.filtered.length === 0) {
        Column({ space: 8 }) {
          Text(this.query.length > 0 ? 'No results' : 'No contacts yet')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text(this.query.length > 0
            ? 'No contact matches your search.'
            : 'Add contacts to your device address book to start new chats here.')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
      } else {
        List({ space: 0 }) {
          ForEach(this.filtered, (c: DeviceContact) => {
            ListItem() {
              this.ContactRow(c)
            }
          }, (c: DeviceContact) => c.key.length > 0 ? c.key : c.phoneNumbers[0])
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 76, endMargin: 0 })
        .backgroundColor($r('app.color.bg_page'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}