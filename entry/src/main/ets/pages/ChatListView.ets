import { cdpBridge, ChatSummary } from '../services/CdpBridge';
import { AppLifecycle } from '../services/AppLifecycle';
import { ContactPickerService, contactPicker } from '../services/ContactPickerService';
import { curves } from '@kit.ArkUI';

const WHATSAPP_GREEN = '#00A884';
const BG = '#F0F2F5';
const TEXT_PRIMARY = '#111B21';
const TEXT_SECONDARY = '#54656F';

@Component
export struct ChatListView {
  @State chats: ChatSummary[] = [];
  @State loading: boolean = true;
  @State searchText: string = '';
  @State inArchived: boolean = false;
  @State inStarred: boolean = false;
  @State statusList: ChatSummary[] = [];
  @State tab: string = 'chats'; // 'chats' | 'status' | 'channels' | 'communities'
  private timer: number | null = null;
  onOpenChat: (name: string) => void = () => {};
  onLoggedOut: () => void = () => {};
  onHandOff: () => void = () => {};

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => {
      if (AppLifecycle.isForeground()) {
        this.refresh();
      }
    }, 5000);
  }

  onPageHide(): void {
    // Pause polling while backgrounded — battery win.
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  onPageShow(): void {
    if (this.timer === null) {
      this.refresh();
      this.timer = setInterval(() => {
        if (AppLifecycle.isForeground()) {
          this.refresh();
        }
      }, 5000);
    }
  }

  aboutToDisappear(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  /** Launch the system contact picker and open a thread with the selected number. */
  private async startChatFromContact(): Promise<void> {
    const digits = await contactPicker.pickSinglePhoneNumber();
    if (digits === null || digits.length === 0) {
      return;
    }
    const jid = ContactPickerService.toWhatsAppJid(digits);
    this.onOpenChat(jid);
  }

  private async refresh(): Promise<void> {
    // If we're inside a search/archived/starred view, don't clobber it with
    // the plain polling refresh — only the main list auto-refreshes.
    if (this.searchText.length > 0 || this.inArchived || this.inStarred) {
      return;
    }
    if (this.tab === 'status') {
      const list = await cdpBridge.scrapeStatus();
      if (list.length > 0) {
        this.statusList = list;
      }
      this.loading = false;
      return;
    }
    if (this.tab === 'channels') {
      const list = await cdpBridge.scrapeChannels();
      if (list.length > 0) {
        this.chats = list;
      }
      this.loading = false;
      return;
    }
    if (this.tab === 'communities') {
      const list = await cdpBridge.scrapeCommunities();
      if (list.length > 0) {
        this.chats = list;
      }
      this.loading = false;
      return;
    }
    const list = await cdpBridge.scrapeChats();
    if (list.length > 0) {
      this.chats = list;
    }
    this.loading = false;
  }

  private async switchTab(t: string): Promise<void> {
    this.tab = t;
    this.searchText = '';
    this.inArchived = false;
    this.inStarred = false;
    if (t === 'status') {
      const list = await cdpBridge.openStatusTab();
      if (list.length > 0) {
        this.statusList = list;
      }
    } else if (t === 'channels') {
      const list = await cdpBridge.openChannelsTab();
      if (list.length > 0) {
        this.chats = list;
      }
    } else if (t === 'communities') {
      const list = await cdpBridge.openCommunitiesTab();
      if (list.length > 0) {
        this.chats = list;
      }
    } else {
      await cdpBridge.searchChats('');
      this.refresh();
    }
    this.loading = false;
  }

  private async onSearch(v: string): Promise<void> {
    this.searchText = v;
    const list = await cdpBridge.searchChats(v);
    if (list.length > 0) {
      this.chats = list;
    }
    this.loading = false;
  }

  private async openArchived(): Promise<void> {
    this.inArchived = true;
    this.inStarred = false;
    const list = await cdpBridge.openArchived();
    if (list.length > 0) {
      this.chats = list;
    }
    this.loading = false;
  }

  private async openStarred(): Promise<void> {
    this.inStarred = true;
    this.inArchived = false;
    const list = await cdpBridge.openStarred();
    if (list.length > 0) {
      this.chats = list;
    }
    this.loading = false;
  }

  private async backToMain(): Promise<void> {
    this.inArchived = false;
    this.inStarred = false;
    this.searchText = '';
    await cdpBridge.searchChats('');
    this.refresh();
  }

  @Builder
  TabChip(label: string, key: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.tab === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.tab === key ? WHATSAPP_GREEN : TEXT_SECONDARY)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.tab === key ? '#E7FCE3' : '#FFFFFF')
      .borderRadius(16)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.switchTab(key);
      })
  }

  @Builder
  StatusRow(status: ChatSummary) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: 48, height: 48 })
          .fill(WHATSAPP_GREEN)
        if (status.avatarUrl.length > 0) {
          Image(status.avatarUrl)
            .width(48)
            .height(48)
            .borderRadius(24)
        }
      }
      .width(48)
      .height(48)

      Column({ space: 4 }) {
        Text(status.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_PRIMARY)
          .maxLines(1)
        Text('Tap to view')
          .fontSize(13)
          .fontColor(TEXT_SECONDARY)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor('#FFFFFF')
    .onClick(() => {
      this.onOpenChat(status.name);
    })
  }

  @Builder
  ChatRow(chat: ChatSummary) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: 48, height: 48 })
          .fill('#00A884')
        Text(chat.name.charAt(0).toUpperCase())
          .fontSize(20)
          .fontColor('#FFFFFF')
      }
      .width(48)
      .height(48)

      Column({ space: 4 }) {
        Row() {
          Text(chat.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
            .maxLines(1)
            .layoutWeight(1)
          if (chat.unread > 0) {
            Text(chat.unread.toString())
              .fontSize(11)
              .fontColor('#FFFFFF')
              .backgroundColor(WHATSAPP_GREEN)
              .borderRadius(10)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
        .width('100%')

        Row() {
          Text(chat.preview)
            .fontSize(14)
            .fontColor(TEXT_SECONDARY)
            .maxLines(1)
            .layoutWeight(1)
          Text(chat.time)
            .fontSize(12)
            .fontColor(TEXT_SECONDARY)
        }
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor('#FFFFFF')
    .onClick(() => {
      this.onOpenChat(chat.id.length > 0 ? chat.id : chat.name);
    })
  }

  build() {
    Column() {
      Row() {
        Text('WhatIsIt')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_PRIMARY)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.arrowshape_up_to_line'))
          .fontSize(18)
          .fontColor(['#FFFFFF'])
          .margin({ right: 16 })
          .onClick(() => {
            this.onHandOff();
          })
        SymbolGlyph($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'))
          .fontSize(18)
          .fontColor(['#EA4335'])
          .onClick(() => {
            this.onLoggedOut();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(WHATSAPP_GREEN)

      // Search bar.
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([TEXT_SECONDARY])
        TextInput({ placeholder: 'Search chats', text: this.searchText })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor('#FFFFFF')
          .borderRadius(20)
          .onChange((v: string) => {
            this.onSearch(v);
          })
        if (this.searchText.length > 0 || this.inArchived || this.inStarred) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            .fontColor([TEXT_SECONDARY])
            .onClick(() => {
              this.backToMain();
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(BG)

      // Archived / Starred entry rows (main view only).
      if (!this.inArchived && !this.inStarred && this.searchText.length === 0) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.archivebox'))
            .fontSize(18)
            .fontColor([TEXT_PRIMARY])
          Text('Archived')
            .fontSize(15)
            .fontColor(TEXT_PRIMARY)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([TEXT_SECONDARY])
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor('#FFFFFF')
        .onClick(() => {
          this.openArchived();
        })

        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.star'))
            .fontSize(18)
            .fontColor([TEXT_PRIMARY])
          Text('Starred messages')
            .fontSize(15)
            .fontColor(TEXT_PRIMARY)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([TEXT_SECONDARY])
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor('#FFFFFF')
        .onClick(() => {
          this.openStarred();
        })
      }

      // Tab bar: Chats / Status / Channels / Communities.
      Row() {
        this.TabChip('Chats', 'chats')
        this.TabChip('Status', 'status')
        this.TabChip('Channels', 'channels')
        this.TabChip('Communities', 'communities')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(BG)

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(WHATSAPP_GREEN)
          Text('Loading chats…')
            .fontSize(14)
            .fontColor(TEXT_SECONDARY)
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.tab === 'status') {
        if (this.statusList.length === 0) {
          Column({ space: 8 }) {
            Text('No statuses')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT_PRIMARY)
            Text('Statuses will appear here when available.')
              .fontSize(13)
              .fontColor(TEXT_SECONDARY)
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 1 }) {
            ForEach(this.statusList, (status: ChatSummary) => {
              ListItem() {
                this.StatusRow(status)
              }
            }, (status: ChatSummary) => status.id)
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(BG)
        }
      } else if (this.chats.length === 0) {
        Column({ space: 8 }) {
          Text('No chats yet')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
          Text('If the session is active, chats appear here.')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 1 }) {
          ForEach(this.chats, (chat: ChatSummary) => {
            ListItem() {
              this.ChatRow(chat)
            }
          }, (chat: ChatSummary) => chat.id)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(BG)
        .animation({ duration: 250, curve: curves.springMotion(0.35, 0.85) })
      }

      // Floating "New chat" — system contact picker (no READ_CONTACTS needed).
      Button() {
        Text('+')
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width(56)
      .height(56)
      .backgroundColor(WHATSAPP_GREEN)
      .borderRadius(28)
      .shadow({ radius: 12, color: '#33000000', offsetY: 4 })
      .align(Alignment.BottomEnd)
      .margin({ right: 20, bottom: 20 })
      .onClick(() => {
        this.startChatFromContact();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }
}
