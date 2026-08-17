import { cdpBridge, ChatSummary, ChannelSummary, CallRecord } from '../services/CdpBridge';
import { AppLifecycle } from '../services/AppLifecycle';
import { Theme } from '../styles/Theme';
import { curves } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';

@Component
export struct ChatListView {
  @State chats: ChatSummary[] = [];
  @State loading: boolean = true;
  @State searchText: string = '';
  @State filter: string = 'all'; // 'all' | 'channels' | 'archived' | 'starred'
  @State statusList: ChatSummary[] = [];
  @State channels: ChannelSummary[] = [];
  @State calls: CallRecord[] = [];
  @State tab: string = 'chats'; // 'chats' | 'status' | 'calls' | 'communities'
  @State isRtl: boolean = false;
  @State failedAvatars: Set<string> = new Set();
  private timer: number | null = null;
  onOpenChat: (name: string) => void = () => {};
  onLoggedOut: () => void = () => {};
  onHandOff: () => void = () => {};
  onNewChat: () => void = () => {};
  onComposeStatus: () => void = () => {};
  onFindChannels: () => void = () => {};

  aboutToAppear(): void {
    this.updateDirection();
    this.refresh();
    this.timer = setInterval(() => {
      if (AppLifecycle.isForeground()) {
        this.refresh();
      }
    }, 5000);
  }

  private updateDirection(): void {
    let lang = 'en';
    try {
      lang = i18n.getSystemLanguage();
    } catch (e) {
      // ignore
    }
    this.isRtl = i18n.isRTL(lang);
  }

  onPageHide(): void {
    // Pause polling while backgrounded — battery win.
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  onPageShow(): void {
    this.updateDirection();
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
  private startChatFromContact(): void {
    this.onNewChat();
  }

  private async refresh(): Promise<void> {
    // If we're searching or in a sub-filter, don't clobber it with the plain poll.
    if (this.searchText.length > 0 || this.filter !== 'all') {
      return;
    }
    if (this.tab === 'status') {
      const list = await cdpBridge.scrapeStatus();
      if (list.length > 0) {
        this.statusList = list;
      }
      const ch = await cdpBridge.scrapeChannels();
      if (ch.length > 0) {
        this.channels = ch;
      }
      this.loading = false;
      return;
    }
    if (this.tab === 'communities') {
      const list = await cdpBridge.scrapeCommunities();
      this.chats = list;
      this.loading = false;
      return;
    }
    if (this.tab === 'calls') {
      const list = await cdpBridge.scrapeCalls();
      if (list.length > 0) {
        this.calls = list;
      }
      this.loading = false;
      return;
    }
    const list = await cdpBridge.scrapeChats();
    if (list.length > 0) {
      // The Chats tab shows personal chats + groups only; channels live
      // under the "Channels" filter and the Status tab.
      this.chats = list.filter((c: ChatSummary) => !c.isChannel);
    }
    this.loading = false;
  }

  private async switchTab(t: string): Promise<void> {
    this.tab = t;
    this.searchText = '';
    this.filter = 'all';
    if (t === 'status') {
      const list = await cdpBridge.openStatusTab();
      if (list.length > 0) {
        this.statusList = list;
      }
      const ch = await cdpBridge.scrapeChannels();
      if (ch.length > 0) {
        this.channels = ch;
      }
    } else if (t === 'communities') {
      const list = await cdpBridge.openCommunitiesTab();
      this.chats = list;
    } else if (t === 'calls') {
      const list = await cdpBridge.scrapeCalls();
      if (list.length > 0) {
        this.calls = list;
      }
    } else {
      await cdpBridge.searchChats('');
      this.refresh();
    }
    this.loading = false;
  }

  private async switchFilter(f: string): Promise<void> {
    this.filter = f;
    this.searchText = '';
    if (f === 'archived') {
      const list = await cdpBridge.openArchived();
      this.chats = list;
    } else if (f === 'starred') {
      const list = await cdpBridge.openStarred();
      this.chats = list;
    } else if (f === 'channels') {
      const list = await cdpBridge.openChannelsTab();
      this.chats = list;
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

  private async backToMain(): Promise<void> {
    this.searchText = '';
    this.filter = 'all';
    await cdpBridge.searchChats('');
    this.refresh();
  }

  @Builder
  FilterChip(label: string, key: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.filter === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.filter === key ? $r('app.color.brand') : $r('app.color.ink_subtle'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.filter === key ? $r('app.color.brand_soft') : $r('app.color.surface'))
      .borderRadius(Theme.RADIUS_CHIP)
      .onClick(() => {
        this.switchFilter(key);
      })
  }

  @Builder
  StatusRow(status: ChatSummary) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill($r('app.color.brand'))
        Text(status.name.charAt(0).toUpperCase())
          .fontSize(20)
          .fontColor($r('app.color.brand_text'))
        if (status.avatarUrl.length > 0 && !this.failedAvatars.has(status.id)) {
          Image(status.avatarUrl)
            .width(Theme.AVATAR_SIZE)
            .height(Theme.AVATAR_SIZE)
            .borderRadius(Theme.AVATAR_SIZE / 2)
            .onError(() => {
              this.markAvatarFailed(status.id);
            })
        }
      }
      .width(Theme.AVATAR_SIZE)
      .height(Theme.AVATAR_SIZE)

      Column({ space: 4 }) {
        Text(status.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
        Text('Tap to view')
          .fontSize(13)
          .fontColor($r('app.color.ink_subtle'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(Theme.ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      this.onOpenChat(status.name);
    })
  }

  @Builder
  MyStatusRow() {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill($r('app.color.brand'))
        SymbolGlyph($r('sys.symbol.person_fill'))
          .fontSize(22)
          .fontColor([$r('app.color.brand_text')])
        Circle({ width: 22, height: 22 })
          .fill($r('app.color.surface'))
          .position({ x: Theme.AVATAR_SIZE - 14, y: Theme.AVATAR_SIZE - 14 })
        Circle({ width: 18, height: 18 })
          .fill($r('app.color.brand'))
          .position({ x: Theme.AVATAR_SIZE - 12, y: Theme.AVATAR_SIZE - 12 })
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(10)
          .fontColor([$r('app.color.brand_text')])
          .position({ x: Theme.AVATAR_SIZE - 8, y: Theme.AVATAR_SIZE - 8 })
      }
      .width(Theme.AVATAR_SIZE)
      .height(Theme.AVATAR_SIZE)

      Column({ space: 4 }) {
        Text('My status')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
        Text('Tap to add status update')
          .fontSize(13)
          .fontColor($r('app.color.ink_subtle'))
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
      this.onComposeStatus();
    })
  }

  @Builder
  ChannelRow(channel: ChannelSummary) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill($r('app.color.brand'))
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
        Text('Followed')
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
      this.onOpenChat(channel.id.length > 0 ? channel.id : channel.name);
    })
  }

  @Builder
  CallRow(call: CallRecord) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill(call.missed ? $r('app.color.danger') : $r('app.color.brand'))
        SymbolGlyph(call.dir === 'out' ? $r('sys.symbol.arrow_up_right') : $r('sys.symbol.arrow_down_left'))
          .fontSize(20)
          .fontColor([$r('app.color.brand_text')])
      }
      .width(Theme.AVATAR_SIZE)
      .height(Theme.AVATAR_SIZE)

      Column({ space: 4 }) {
        Text(call.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
        Text(this.callSubtitle(call))
          .fontSize(13)
          .fontColor(call.missed ? $r('app.color.danger') : $r('app.color.ink_subtle'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(call.time)
        .fontSize(12)
        .fontColor($r('app.color.ink_faded'))
        .margin({ left: 8 })
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
      if (call.peer.length > 0) {
        this.onOpenChat(call.peer);
      }
    })
  }

  private callSubtitle(call: CallRecord): string {
    const kind = call.video ? 'video call' : 'call';
    if (call.missed) {
      return 'Missed ' + kind;
    }
    if (call.dir === 'out') {
      return 'Outgoing ' + kind;
    }
    return 'Incoming ' + kind;
  }

  @Builder
  SectionHeader(title: string, action: string, onAction: () => void) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink_subtle'))
        .layoutWeight(1)
      if (action.length > 0) {
        Text(action)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            onAction();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 6 })
    .backgroundColor($r('app.color.bg_page'))
  }

  private tabTitle(): string {
    if (this.tab === 'status') {
      return 'Status';
    }
    if (this.tab === 'calls') {
      return 'Calls';
    }
    if (this.tab === 'communities') {
      return 'Communities';
    }
    return 'WhatIsIt';
  }

  private markAvatarFailed(id: string): void {
    if (!this.failedAvatars.has(id)) {
      this.failedAvatars.add(id);
      this.failedAvatars = new Set(this.failedAvatars);
    }
  }

  @Builder
  ChatRow(chat: ChatSummary) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: Theme.AVATAR_SIZE, height: Theme.AVATAR_SIZE })
          .fill($r('app.color.brand'))
        Text(chat.name.charAt(0).toUpperCase())
          .fontSize(20)
          .fontColor($r('app.color.brand_text'))
        if (chat.avatarUrl.length > 0 && !this.failedAvatars.has(chat.id)) {
          Image(chat.avatarUrl)
            .width(Theme.AVATAR_SIZE)
            .height(Theme.AVATAR_SIZE)
            .borderRadius(Theme.AVATAR_SIZE / 2)
            .onError(() => {
              this.markAvatarFailed(chat.id);
            })
        }
      }
      .width(Theme.AVATAR_SIZE)
      .height(Theme.AVATAR_SIZE)

      Column({ space: 4 }) {
        Row() {
          Text(chat.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
            .maxLines(1)
            .layoutWeight(1)
          Text(chat.time)
            .fontSize(12)
            .fontColor($r('app.color.ink_faded'))
            .margin({ left: 8 })
        }
        .width('100%')

        Row({ space: 6 }) {
          Text(chat.preview)
            .fontSize(14)
            .fontColor($r('app.color.ink_subtle'))
            .maxLines(1)
            .layoutWeight(1)
          if (chat.unread > 0) {
            Text(chat.unread.toString())
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.brand_text'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(10)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
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
      this.onOpenChat(chat.id.length > 0 ? chat.id : chat.name);
    })
  }

  @Builder
  TabItem(label: string, key: string, icon: Resource, iconOn: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(this.tab === key ? iconOn : icon)
        .fontSize(22)
        .fontColor([this.tab === key ? $r('app.color.brand') : $r('app.color.tab_inactive')])
        .animation({ duration: 120 })
      Text(label)
        .fontSize(10)
        .fontWeight(this.tab === key ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === key ? $r('app.color.brand') : $r('app.color.tab_inactive'))
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .stateStyles({
      pressed: {
        .opacity(0.6)
      }
    })
    .onClick(() => {
      this.switchTab(key);
    })
  }

  @Builder
  TabBar() {
    Row() {
      this.TabItem('Chats', 'chats',
        $r('sys.symbol.message'), $r('sys.symbol.message_fill'))
      this.TabItem('Status', 'status',
        $r('sys.symbol.circle'), $r('sys.symbol.circle_fill'))
      this.TabItem('Calls', 'calls',
        $r('sys.symbol.phone'), $r('sys.symbol.phone_fill'))
      this.TabItem('Communities', 'communities',
        $r('sys.symbol.person_2'), $r('sys.symbol.person_2_fill'))
    }
    .width('100%')
    .height(Theme.TAB_BAR_HEIGHT)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  build() {
    Stack({ alignContent: this.isRtl ? Alignment.BottomStart : Alignment.BottomEnd }) {
      Column() {
        // Header: large title + trailing actions (iOS style).
        Column() {
          Row() {
            Text(this.tabTitle())
              .fontSize(Theme.TYPE_LARGE_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'))
              .layoutWeight(1)
            if (this.tab === 'status') {
              SymbolGlyph($r('sys.symbol.square_and_pencil'))
                .fontSize(20)
                .fontColor([$r('app.color.ink_subtle')])
                .margin({ right: 16 })
                .onClick(() => {
                  this.onComposeStatus();
                })
            }
            SymbolGlyph($r('sys.symbol.arrowshape_up_to_line'))
              .fontSize(20)
              .fontColor([$r('app.color.ink_subtle')])
              .margin({ right: 16 })
              .onClick(() => {
                this.onHandOff();
              })
            SymbolGlyph($r('sys.symbol.rectangle_and_arrowshape_turn_up_right'))
              .fontSize(20)
              .fontColor([$r('app.color.danger')])
              .onClick(() => {
                this.onLoggedOut();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 4 })

          // Search field (Chats tab only — Status/Calls/Communities have their own layout).
          if (this.tab === 'chats') {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(16)
                .fontColor([$r('app.color.ink_faded')])
              TextInput({ placeholder: 'Search', text: this.searchText })
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
              if (this.searchText.length > 0 || this.filter !== 'all') {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([$r('app.color.ink_subtle')])
                  .onClick(() => {
                    this.backToMain();
                  })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 2 })

        // Filter chips: All / Channels / Archived / Starred (Chats tab only).
        if (this.tab === 'chats') {
          Scroll() {
            Row({ space: 8 }) {
              this.FilterChip('All', 'all')
              this.FilterChip('Channels', 'channels')
              this.FilterChip('Archived', 'archived')
              this.FilterChip('Starred', 'starred')
            }
            .padding({ left: 12, right: 12 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }

        if (this.loading) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color($r('app.color.brand'))
            Text('Loading…')
              .fontSize(13)
              .fontColor($r('app.color.ink_faded'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.tab === 'status') {
          Scroll() {
            Column() {
              this.MyStatusRow()
              this.SectionHeader('Recent updates', '', () => {})
              if (this.statusList.length === 0) {
                Column({ space: 6 }) {
                  Text('No recent updates to show right now')
                    .fontSize(14)
                    .fontColor($r('app.color.ink_subtle'))
                  Text('Statuses from your contacts will appear here.')
                    .fontSize(12)
                    .fontColor($r('app.color.ink_faded'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .alignItems(HorizontalAlign.Start)
              } else {
                List({ space: 0 }) {
                  ForEach(this.statusList, (status: ChatSummary) => {
                    ListItem() {
                      this.StatusRow(status)
                    }
                  }, (status: ChatSummary) => status.id)
                }
                .width('100%')
                .height(this.statusList.length * Theme.ROW_HEIGHT)
                .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 76, endMargin: 0 })
              }
              this.SectionHeader('Channels', 'Find channels', () => {
                this.onFindChannels();
              })
              if (this.channels.length === 0) {
                Column({ space: 6 }) {
                  Text('No channels yet')
                    .fontSize(14)
                    .fontColor($r('app.color.ink_subtle'))
                  Text('Follow channels to see their updates here.')
                    .fontSize(12)
                    .fontColor($r('app.color.ink_faded'))
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .alignItems(HorizontalAlign.Start)
              } else {
                ForEach(this.channels, (channel: ChannelSummary) => {
                  this.ChannelRow(channel)
                }, (channel: ChannelSummary) => channel.id)
              }
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_page'))
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .width('100%')
          .layoutWeight(1)
        } else if (this.tab === 'calls') {
          if (this.calls.length === 0) {
            this.EmptyState('No calls yet', 'Audio and video calls made or received from WhatsApp will appear here.')
          } else {
            List({ space: 0 }) {
              ForEach(this.calls, (call: CallRecord) => {
                ListItem() {
                  this.CallRow(call)
                }
              }, (call: CallRecord) => call.id)
            }
            .width('100%')
            .layoutWeight(1)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 76, endMargin: 0 })
            .backgroundColor($r('app.color.bg_page'))
            .animation({ duration: Theme.DURATION_FAST, curve: curves.springMotion(0.35, 0.85) })
          }
        } else if (this.chats.length === 0) {
          if (this.tab === 'communities') {
            this.EmptyState('No communities yet', 'Communities and groups you belong to will appear here.')
          } else {
            this.EmptyState('No chats yet', 'If the session is active, chats appear here.')
          }
        } else {
          List({ space: 0 }) {
            ForEach(this.chats, (chat: ChatSummary) => {
              ListItem() {
                this.ChatRow(chat)
              }
            }, (chat: ChatSummary) => chat.id)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 76, endMargin: 0 })
          .backgroundColor($r('app.color.bg_page'))
          .animation({ duration: Theme.DURATION_FAST, curve: curves.springMotion(0.35, 0.85) })
        }

        this.TabBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // Floating "New chat" — opens WhatIsIt's own contacts list (Chats tab
      // only, mirroring WhatsApp iOS). Position mirrors with RTL languages.
      if (this.tab === 'chats') {
        Button() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(24)
            .fontColor([$r('app.color.brand_text')])
        }
        .width(Theme.FAB_SIZE)
        .height(Theme.FAB_SIZE)
        .backgroundColor($r('app.color.brand'))
        .borderRadius(Theme.FAB_SIZE / 2)
        .shadow({ radius: 12, color: '#33000000', offsetY: 4 })
        .margin({ left: this.isRtl ? 20 : 0, right: this.isRtl ? 0 : 20, bottom: Theme.TAB_BAR_HEIGHT + 16 })
        .stateStyles({
          pressed: {
            .backgroundColor($r('app.color.brand_pressed'))
          }
        })
        .onClick(() => {
          this.startChatFromContact();
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  EmptyState(title: string, subtitle: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink'))
      Text(subtitle)
        .fontSize(13)
        .fontColor($r('app.color.ink_subtle'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}