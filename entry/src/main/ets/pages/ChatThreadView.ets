import { cdpBridge, MessageEntry, MediaMessage } from '../services/CdpBridge';
import { remoteFeatures } from '../services/RemoteFeatures';
import { mediaSender, MediaSendMode } from '../services/MediaSender';
import { mediaDownloader } from '../services/MediaDownloader';
import { e2ee, CipherRow } from '../services/E2eeService';
import { callService } from '../services/CallService';
import { localNotifications } from '../services/LocalNotifications';
import { CallSurfaceView } from './CallSurfaceView';
import { Theme } from '../styles/Theme';
import { AppLifecycle } from '../services/AppLifecycle';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { media } from '@kit.MediaKit';
import { unifiedDataChannel } from '@kit.ArkData';
import { curves, dragController } from '@kit.ArkUI';

const TAG = 'ChatThreadView';
const DOMAIN = 0x0000;
const WHATSAPP_GREEN = '#00A884';
const BG = '#F0F2F5';
const TEXT_PRIMARY = '#111B21';
const TEXT_SECONDARY = '#54656F';

@Component
export struct ChatThreadView {
  chatName: string = '';
  onBack: () => void = () => {};
  @State messages: MessageEntry[] = [];
  @State mediaMessages: MediaMessage[] = [];
  @State mediaPaths: Map<string, string> = new Map();
  @State loading: boolean = true;
  @State draft: string = '';
  @State callState: string = 'none';
  @State sendingLocation: boolean = false;
  @State sendingMedia: boolean = false;
  @State callRoomUrl: string = '';
  @State activeCallId: string = '';
  @State callIsVideo: boolean = false;
  @State replyTargetId: string = '';
  @State replyDraft: string = '';
  private timer: number | null = null;
  private avPlayer: media.AVPlayer | null = null;

  aboutToAppear(): void {
    cdpBridge.openChat(this.chatName);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    mediaDownloader.init(ctx);
    this.loadLocalMessages();
    this.refresh();
    this.startPollers();
  }

  onPageHide(): void {
    // Pause all polling while backgrounded — battery win.
    this.stopPollers();
  }

  onPageShow(): void {
    if (this.timer === null) {
      this.startPollers();
    }
  }

  aboutToDisappear(): void {
    this.stopPollers();
  }

  private startPollers(): void {
    this.stopPollers();
    // Messages: 5s while foregrounded.
    this.timer = setInterval(() => {
      if (AppLifecycle.isForeground()) {
        this.refresh();
      }
    }, 5000);
  }

  private stopPollers(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  private async refresh(): Promise<void> {
    const list = await cdpBridge.scrapeMessages();
    if (list.length > 0) {
      this.messages = list;
      this.persistScraped(list);
    }
    const media = await cdpBridge.scrapeMediaMessages();
    if (media.length > 0) {
      this.mediaMessages = media;
      // Kick off native downloads for any media we haven't fetched yet.
      for (const m of media) {
        this.downloadMedia(m);
      }
    }
    this.loading = false;
  }

  /** Encrypt newly-scraped messages and persist them (dedupe by id). */
  private async persistScraped(list: MessageEntry[]): Promise<void> {
    for (const msg of list) {
      if (msg.id.length === 0 || msg.text.length === 0) {
        continue;
      }
      const row = await e2ee.encryptMessage(this.chatName, msg.text);
      if (row !== null) {
        row.id = msg.id;
        await e2ee.saveMessage(row);
      }
    }
  }

  /** Load this chat's previously-persisted messages from local encrypted store. */
  private async loadLocalMessages(): Promise<void> {
    const rows = await e2ee.getMessages(this.chatName);
    if (rows.length === 0) {
      return;
    }
    const local: MessageEntry[] = [];
    for (const row of rows) {
      const text = await e2ee.decryptMessage(row);
      if (text.length > 0) {
        const m = new MessageEntry();
        m.id = row.id;
        m.text = text;
        m.dir = 'in';
        m.time = '';
        local.push(m);
      }
    }
    if (local.length > 0) {
      // Merge local history with anything live already shown.
      const merged = local.concat(this.messages);
      const seen: Set<string> = new Set();
      this.messages = merged.filter((m: MessageEntry) => {
        if (seen.has(m.id)) {
          return false;
        }
        seen.add(m.id);
        return true;
      });
    }
  }

  private async send(): Promise<void> {
    const text = this.draft.trim();
    if (text.length === 0) {
      return;
    }
    let ok = false;
    if (this.replyTargetId.length > 0) {
      ok = await cdpBridge.sendReply(this.replyTargetId, text);
    } else {
      ok = await cdpBridge.sendMessage(text);
    }
    if (ok) {
      this.draft = '';
      this.replyTargetId = '';
      this.replyDraft = '';
      this.refresh();
    }
  }

  /**
   * Share the current GPS location into the chat via RemoteFeatures.
   * Requests the location permission at runtime if not yet granted, then
   * resolves a single current fix and sends it as a maps-link text message.
   */
  private async shareLocation(): Promise<void> {
    if (this.sendingLocation) {
      return;
    }
    this.sendingLocation = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok = await remoteFeatures.shareCurrentLocation(ctx, this.chatName);
      if (ok) {
        this.refresh();
      }
    } finally {
      this.sendingLocation = false;
    }
  }

  /** Native gallery/camera pick → send into the chat via the page's file input. */
  private async sendMedia(mode: MediaSendMode): Promise<void> {
    if (this.sendingMedia) {
      return;
    }
    this.sendingMedia = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      mediaDownloader.init(ctx);
      const ok = await mediaSender.pickAndSend(ctx, mode);
      if (ok) {
        this.refresh();
      }
    } finally {
      this.sendingMedia = false;
    }
  }

  /**
   * Start a WhatsApp-native call (audio or video) via the backend.
   * Signaling goes to /call; media rides the WS relay; the native
   * CallSurfaceView renders the remote video on an XComponent.
   */
  private async startWhatsAppCall(video: boolean): Promise<void> {
    try {
      const ok = await callService.startCall(this.chatName, video);
      if (!ok) {
        hilog.warn(DOMAIN, TAG, 'startWhatsAppCall failed (backend unreachable?)');
        return;
      }
      this.activeCallId = callService.getActiveCallId();
      this.callIsVideo = video;
      this.callRoomUrl = 'call:' + this.activeCallId; // open the native surface
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startWhatsAppCall failed: %{public}s', JSON.stringify(err));
    }
  }

  private closeCallSurface(): void {
    callService.endCall();
    this.callRoomUrl = '';
    this.activeCallId = '';
  }

  /** Download a scraped media URL into the sandbox for native rendering. */
  private async downloadMedia(m: MediaMessage): Promise<void> {
    if (this.mediaPaths.has(m.id)) {
      return;
    }
    const url = m.thumbUrl.length > 0 ? m.thumbUrl : m.mediaUrl;
    if (url.length === 0) {
      return;
    }
    let ext = 'jpg';
    if (m.type === 'video') {
      ext = 'mp4';
    } else if (m.type === 'audio') {
      ext = 'm4a';
    }
    const cookies = await cdpBridge.getSessionCookies();
    const path = await mediaDownloader.download(url, ext, cookies);
    if (path.length > 0) {
      const next = new Map(this.mediaPaths);
      next.set(m.id, path);
      this.mediaPaths = next;
    }
  }

  /** Play a downloaded voice note with the native AVPlayer. */
  private async playAudio(m: MediaMessage): Promise<void> {
    const path = this.mediaPaths.get(m.id);
    if (path === undefined) {
      // Not downloaded yet — kick the download, then play.
      await this.downloadMedia(m);
      const p = this.mediaPaths.get(m.id);
      if (p === undefined) {
        return;
      }
      this.playAudioFile(p);
      return;
    }
    this.playAudioFile(path);
  }

  private async playAudioFile(path: string): Promise<void> {
    try {
      const avPlayer = await media.createAVPlayer();
      avPlayer.url = path;
      await avPlayer.prepare();
      await avPlayer.play();
      // Keep a ref so GC doesn't kill it mid-play; stop on completion.
      this.avPlayer = avPlayer;
      avPlayer.on('stateChange', (state) => {
        if (state === 'completed' || state === 'stopped' || state === 'error') {
          avPlayer.release();
          this.avPlayer = null;
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'playAudioFile failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Grab-and-drop share: drag a message out to any HarmonyOS share target. */
  private async startDragMessage(msg: MessageEntry, event: GestureEvent): Promise<void> {
    try {
      const data = new unifiedDataChannel.UnifiedData();
      const record = new unifiedDataChannel.PlainText();
      record.textContent = msg.text;
      data.addRecord(record);
      const info: dragController.DragInfo = {
        pointerId: event.fingerList[0].id,
        data: data,
        extraParams: JSON.stringify({ type: 'message', text: msg.text, chat: this.chatName }),
      };
      const ctx = this.getUIContext();
      await ctx.getDragController().executeDrag(this.DragPreview(msg.text), info);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startDragMessage failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Grab-and-drop share: drag a media URL out to any share target. */
  private async startDragMedia(m: MediaMessage, event: GestureEvent): Promise<void> {
    try {
      const data = new unifiedDataChannel.UnifiedData();
      const record = new unifiedDataChannel.PlainText();
      record.textContent = m.mediaUrl.length > 0 ? m.mediaUrl : m.thumbUrl;
      data.addRecord(record);
      const info: dragController.DragInfo = {
        pointerId: event.fingerList[0].id,
        data: data,
        extraParams: JSON.stringify({ type: 'media', url: m.mediaUrl, chat: this.chatName }),
      };
      const ctx = this.getUIContext();
      await ctx.getDragController().executeDrag(this.DragPreview(m.mediaUrl.length > 0 ? m.mediaUrl : m.thumbUrl), info);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startDragMedia failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Floating preview shown while dragging. */
  @Builder
  DragPreview(content: string) {
    Column() {
      Text(content)
        .fontSize(13)
        .fontColor(Theme.INK)
        .maxLines(3)
    }
    .width(200)
    .padding(12)
    .backgroundColor(Theme.SURFACE)
    .borderRadius(Theme.RADIUS_CARD)
    .shadow({ radius: 12, color: '#33000000', offsetY: 4 })
  }

  @Builder
  Bubble(msg: MessageEntry) {
    Column({ space: 4 }) {
      if (msg.replyTo.length > 0) {
        Text(msg.replyTo)
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .maxLines(2)
          .backgroundColor(Theme.SURFACE_SUBTLE)
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }
      Text(msg.text)
        .fontSize(15)
        .fontColor(TEXT_PRIMARY)
        .lineHeight(20)
      if (msg.reactions.length > 0) {
        Text(msg.reactions)
          .fontSize(13)
          .backgroundColor(Theme.SURFACE_SUBTLE)
          .borderRadius(Theme.RADIUS_CHIP)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .alignSelf(ItemAlign.End)
      }
      Row({ space: 4 }) {
        Text(msg.time)
          .fontSize(11)
          .fontColor(TEXT_SECONDARY)
        if (msg.dir === 'out') {
          if (msg.status === 'read') {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor([Theme.READ])
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor([Theme.READ])
          } else if (msg.status === 'delivered') {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor([Theme.DELIVERED])
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor([Theme.DELIVERED])
          } else if (msg.status === 'sent') {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor([Theme.DELIVERED])
          }
        }
      }
      .alignSelf(ItemAlign.End)
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(msg.dir === 'out' ? '#D9FDD3' : '#FFFFFF')
    .borderRadius(12)
    .alignSelf(msg.dir === 'out' ? ItemAlign.End : ItemAlign.Start)
    .margin({ left: msg.dir === 'out' ? 40 : 8, right: msg.dir === 'out' ? 8 : 40, top: 4, bottom: 4 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.97, y: 0.97 })))
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction((event: GestureEvent) => {
          this.replyTargetId = msg.id;
          this.replyDraft = msg.text;
        })
    )
    .gesture(
      PanGesture({ fingers: 1, distance: 8 })
        .onActionStart((event: GestureEvent) => {
          this.startDragMessage(msg, event);
        })
    )
  }

  /** Native media bubble — downloads the scraped URL and renders an Image/Video. */
  @Builder
  MediaBubble(m: MediaMessage) {
    Column({ space: 4 }) {
      if (m.type === 'video') {
        this.VideoContent(m)
      } else if (m.type === 'audio') {
        this.AudioContent(m)
      } else {
        this.ImageContent(m)
      }
      Text(m.time)
        .fontSize(11)
        .fontColor(TEXT_SECONDARY)
        .alignSelf(ItemAlign.End)
    }
    .padding(4)
    .backgroundColor(m.dir === 'out' ? '#D9FDD3' : '#FFFFFF')
    .borderRadius(12)
    .alignSelf(m.dir === 'out' ? ItemAlign.End : ItemAlign.Start)
    .margin({ left: m.dir === 'out' ? 40 : 8, right: m.dir === 'out' ? 8 : 40, top: 4, bottom: 4 })
    .gesture(
      PanGesture({ fingers: 1, distance: 8 })
        .onActionStart((event: GestureEvent) => {
          this.startDragMedia(m, event);
        })
    )
  }

  @Builder
  AudioContent(m: MediaMessage) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.play'))
        .fontSize(18)
        .fontColor([Theme.ACCENT])
      if (this.mediaPaths.has(m.id)) {
        Text('Play voice note')
          .fontSize(14)
          .fontColor(TEXT_PRIMARY)
      } else {
        Text('Loading…')
          .fontSize(14)
          .fontColor(TEXT_SECONDARY)
      }
    }
    .width(180)
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor(Theme.SURFACE_SUBTLE)
    .borderRadius(Theme.RADIUS_CHIP)
    .onClick(() => {
      this.playAudio(m);
    })
  }

  @Builder
  ImageContent(m: MediaMessage) {
    if (this.mediaPaths.has(m.id)) {
      Image(this.mediaPaths.get(m.id) as string)
        .width(180)
        .height(180)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.rectangle_stack'))
          .fontSize(28)
          .fontColor([Theme.INK_FADED])
      }
      .width(180)
      .height(180)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#E4E6EB')
      .borderRadius(8)
    }
  }

  @Builder
  VideoContent(m: MediaMessage) {
    if (this.mediaPaths.has(m.id)) {
      Image(this.mediaPaths.get(m.id) as string)
        .width(180)
        .height(180)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.play'))
          .fontSize(28)
          .fontColor([Theme.INK_FADED])
      }
      .width(180)
      .height(180)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#E4E6EB')
      .borderRadius(8)
    }
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
          .onClick(() => {
            this.onBack();
          })
        Text(this.chatName)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .margin({ left: 8 })
        SymbolGlyph($r('sys.symbol.phone'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
          .margin({ left: 8 })
          .onClick(() => {
            this.startWhatsAppCall(false);
          })
        SymbolGlyph($r('sys.symbol.video'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
          .margin({ left: 12 })
          .onClick(() => {
            this.startWhatsAppCall(true);
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .backgroundColor(WHATSAPP_GREEN)

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(WHATSAPP_GREEN)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.messages.length === 0) {
        Column({ space: 8 }) {
          Text('No messages')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_PRIMARY)
          Text('Messages will appear when the session is active.')
            .fontSize(13)
            .fontColor(TEXT_SECONDARY)
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.messages, (msg: MessageEntry) => {
            ListItem() {
              this.Bubble(msg)
            }
          }, (msg: MessageEntry) => msg.id)
          ForEach(this.mediaMessages, (m: MediaMessage) => {
            ListItem() {
              this.MediaBubble(m)
            }
          }, (m: MediaMessage) => m.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 8, bottom: 8 })
      }

      // Reply indicator (set by long-pressing a message).
      if (this.replyTargetId.length > 0) {
        Row({ space: 8 }) {
          Text('Replying to: ' + this.replyDraft)
            .fontSize(12)
            .fontColor(TEXT_SECONDARY)
            .maxLines(1)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            .fontColor([TEXT_SECONDARY])
            .onClick(() => {
              this.replyTargetId = '';
              this.replyDraft = '';
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .backgroundColor(Theme.SURFACE_SUBTLE)
      }

      Row({ space: 8 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(18)
            .fontColor([TEXT_PRIMARY])
        }
        .width(44)
        .height(44)
        .backgroundColor('#FFFFFF')
        .enabled(!this.sendingMedia)
        .onClick(() => {
          this.sendMedia('camera');
        })
        Button() {
          SymbolGlyph($r('sys.symbol.rectangle_stack'))
            .fontSize(18)
            .fontColor([TEXT_PRIMARY])
        }
        .width(44)
        .height(44)
        .backgroundColor('#FFFFFF')
        .enabled(!this.sendingMedia)
        .onClick(() => {
          this.sendMedia('gallery');
        })
        TextInput({ placeholder: 'Message', text: this.draft })
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor('#FFFFFF')
          .borderRadius(22)
          .onChange((v: string) => {
            this.draft = v;
          })
          .onSubmit(() => {
            this.send();
          })
        Button() {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(44)
        .height(44)
        .backgroundColor(WHATSAPP_GREEN)
        .enabled(!this.sendingMedia)
        .onClick(() => {
          this.send();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .backgroundColor(BG)

      // In-shell native WhatsApp call surface (overlay on the thread).
      if (this.callRoomUrl.length > 0) {
        CallSurfaceView({
          chatName: this.chatName,
          callId: this.activeCallId,
          isVideo: this.callIsVideo,
          onClose: () => {
            this.closeCallSurface();
          }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }
}
