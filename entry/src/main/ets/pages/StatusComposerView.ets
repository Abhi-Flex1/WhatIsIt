import { cdpBridge } from '../services/CdpBridge';
import { Theme } from '../styles/Theme';

/** Compose a "My status" text update (WhatsApp iOS-style composer). */
@Component
export struct StatusComposerView {
  @State draft: string = '';
  @State sending: boolean = false;
  @State errorMsg: string = '';
  onBack: () => void = () => {};
  onPosted: () => void = () => {};

  private async send(): Promise<void> {
    const text = this.draft.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    this.sending = true;
    this.errorMsg = '';
    const ok = await cdpBridge.sendStatus(text);
    this.sending = false;
    if (ok) {
      this.draft = '';
      this.onPosted();
    } else {
      this.errorMsg = 'Could not publish. Check the backend connection and try again.';
    }
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.ink')])
          .width(36)
          .onClick(() => {
            this.onBack();
          })
        Text('My status')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
        Text(this.sending ? 'Sending…' : 'Send')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.draft.trim().length > 0 && !this.sending ? $r('app.color.brand') : $r('app.color.ink_faded'))
          .onClick(() => {
            this.send();
          })
      }
      .width('100%')
      .height(Theme.HEADER_HEIGHT)
      .padding({ left: 4, right: 16 })
      .backgroundColor($r('app.color.surface'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

      Column({ space: 12 }) {
        Row({ space: 12 }) {
          Circle({ width: 44, height: 44 })
            .fill($r('app.color.brand'))
          SymbolGlyph($r('sys.symbol.person_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.brand_text')])
          Column({ space: 2 }) {
            Text('My status')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
            Text('Only visible to your contacts')
              .fontSize(12)
              .fontColor($r('app.color.ink_subtle'))
          }
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        TextArea({ placeholder: 'Share a text update…', text: this.draft })
          .width('100%')
          .height(160)
          .fontSize(17)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface'))
          .borderRadius(Theme.RADIUS_CARD)
          .padding(12)
          .onChange((v: string) => {
            this.draft = v;
          })

        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .fontSize(13)
            .fontColor($r('app.color.danger'))
            .textAlign(TextAlign.Center)
        }

        Button(this.sending ? 'Publishing…' : 'Publish status')
          .width('100%')
          .height(46)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.brand_text'))
          .enabled(this.draft.trim().length > 0 && !this.sending)
          .borderRadius(Theme.RADIUS_PILL)
          .onClick(() => {
            this.send();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 16 })
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}