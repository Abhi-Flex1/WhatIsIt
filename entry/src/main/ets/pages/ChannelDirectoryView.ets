import { cdpBridge, ChannelSummary } from '../services/CdpBridge';
import { Theme } from '../styles/Theme';
import { curves } from '@kit.ArkUI';

/** "Find channels" — browse the followed WhatsApp channels (iOS-style). */
@Component
export struct ChannelDirectoryView {
  @State channels: ChannelSummary[] = [];
  @State loading: boolean = true;
  @State searchText: string = '';
  @State failedAvatars: Set<string> = new Set();
  onBack: () => void = () => {};
  onOpenChannel: (id: string) => void = () => {};

  aboutToAppear(): void {
    this.refresh();
  }

  private async refresh(): Promise<void> {
    const list = await cdpBridge.scrapeChannels();
    if (list.length > 0) {
      this.channels = list;
    }
    this.loading = false;
  }

  private async onSearch(v: string): Promise<void> {
    this.searchText = v;
    const q = v.toLowerCase();
    const all = await cdpBridge.scrapeChannels();
    const filtered: ChannelSummary[] = [];
    for (const ch of all) {
      if (ch.name.toLowerCase().includes(q) || ch.description.toLowerCase().includes(q)) {
        filtered.push(ch);
      }
    }
    this.channels = filtered;
    this.loading = false;
  }

  private markAvatarFailed(id: string): void {
    if (!this.failedAvatars.has(id)) {
      this.failedAvatars.add(id);
      this.failedAvatars = new Set(this.failedAvatars);
    }
  }

  @Builder
  ChannelRow(channel: ChannelSummary) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill(Theme.avatarColor(channel.id))
        Text(channel.name.charAt(0).toUpperCase())
          .fontSize(20)
          .fontColor($r('app.color.brand_text'))
        if (channel.avatarUrl.length > 0 && !this.failedAvatars.has(channel.id)) {
          Image(channel.avatarUrl)
            .width(Theme.AVATAR_SIZE)
            .height(Theme.AVATAR_SIZE)
            .borderRadius(Theme.AVATAR_SIZE / 2)
            .onError(() => {
              this.markAvatarFailed(channel.id);
            })
        }
      }
      .width(Theme.AVATAR_SIZE)
      .height(Theme.AVATAR_SIZE)

      Column({ space: 3 }) {
        Text(channel.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
        Text(channel.description)
          .fontSize(13)
          .fontColor($r('app.color.ink_subtle'))
          .maxLines(2)
        Text(channel.subscribers > 0 ? this.fmtCount(channel.subscribers) + ' subscribers' : 'Followed')
          .fontSize(12)
          .fontColor($r('app.color.ink_faded'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(92)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.surface'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      }
    })
    .onClick(() => {
      this.onOpenChannel(channel.id.length > 0 ? channel.id : channel.name);
    })
  }

  private fmtCount(n: number): string {
    if (n >= 1000000) {
      return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
    }
    if (n >= 1000) {
      return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'K';
    }
    return n.toString();
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
        Text('Find channels')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Theme.HEADER_HEIGHT)
      .padding({ left: 4, right: 16 })
      .backgroundColor($r('app.color.surface'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([$r('app.color.ink_faded')])
        TextInput({ placeholder: 'Search channels', text: this.searchText })
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
      } else if (this.channels.length === 0) {
        Column({ space: 8 }) {
          Text('No channels')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text('Followed channels will appear here.')
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
          ForEach(this.channels, (channel: ChannelSummary) => {
            ListItem() {
              this.ChannelRow(channel)
            }
          }, (channel: ChannelSummary) => channel.id)
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 76, endMargin: 0 })
        .backgroundColor($r('app.color.bg_page'))
        .animation({ duration: Theme.DURATION_FAST, curve: curves.springMotion(0.35, 0.85) })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
