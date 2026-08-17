import { cdpBridge, MessageEntry, MediaMessage } from '../services/CdpBridge';
import { remoteFeatures } from '../services/RemoteFeatures';
import { mediaSender, MediaSendMode } from '../services/MediaSender';
import { mediaDownloader } from '../services/MediaDownloader';
import { e2ee } from '../services/E2eeService';
import { callService } from '../services/CallService';
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

/** Discriminated entries fed to the lazy message list (date chip, text, media). */
interface MsgEntry {
  kind: 'msg';
  msg: MessageEntry;
  key: string;
  groupStart: boolean;
  groupEnd: boolean;
}
interface MediaEntry {
  kind: 'media';
  media: MediaMessage;
  key: string;
  groupStart: boolean;
  groupEnd: boolean;
}
interface DateEntry {
  kind: 'date';
  label: string;
  key: string;
}
type ThreadEntry = MsgEntry | MediaEntry | DateEntry;

const MONTHS: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class ThreadDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: ThreadEntry[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Object {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  setData(items: ThreadEntry[]): void {
    this.items = items;
    this.listeners.forEach((l: DataChangeListener) => {
      l.onDataReloaded();
    });
  }
}

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
  @State avatarFailed: boolean = false;
  private timer: number | null = null;
  private avPlayer: media.AVPlayer | null = null;
  private scroller: Scroller = new Scroller();
  private dataSource: ThreadDataSource = new ThreadDataSource();
  private lastCount: number = 0;

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
    this.pushEntries();
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

  /** Chronological sort key for scraped time labels ("HH:MM" or "Mmm d"). */
  private timeSortKey(t: string): number {
    const hm = /^(\d{1,2}):(\d{2})$/.exec(t);
    if (hm !== null) {
      // Same-day entries sort after any dated (older) entries.
      return 2000000 + parseInt(hm[1], 10) * 60 + parseInt(hm[2], 10);
    }
    const dm = /^([A-Za-z]{3})\s+(\d{1,2})$/.exec(t);
    if (dm !== null) {
      const mon = MONTHS.indexOf(dm[1]);
      return (mon >= 0 ? mon : 99) * 100 + parseInt(dm[2], 10);
    }
    return 0;
  }

  /** Day label for a time string: "Today" for HH:MM, the date itself otherwise. */
  private dayLabel(t: string): string {
    return /^[A-Za-z]{3}\s+\d{1,2}$/.test(t) ? t : 'Today';
  }

  /**
   * Merge messages + media chronologically, insert a date chip whenever the
   * day changes, and mark consecutive same-sender runs so bubbles can be
   * grouped (tight spacing + tail only on the last of a run).
   */
  private buildEntries(): ThreadEntry[] {
    interface Raw {
      kind: string;
      msg?: MessageEntry;
      media?: MediaMessage;
      dir: string;
      time: string;
      key: string;
    }
    const items: Raw[] = [];
    for (const m of this.messages) {
      items.push({ kind: 'msg', msg: m, dir: m.dir, time: m.time, key: 'msg-' + m.id });
    }
    for (const m of this.mediaMessages) {
      items.push({ kind: 'media', media: m, dir: m.dir, time: m.time, key: 'media-' + m.id });
    }
    items.sort((a: Raw, b: Raw) => this.timeSortKey(a.time) - this.timeSortKey(b.time));

    const out: ThreadEntry[] = [];
    let prevDay = '';
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const day = this.dayLabel(it.time);
      if (day !== prevDay) {
        out.push({ kind: 'date', label: day, key: 'date-' + day + '-' + i });
        prevDay = day;
      }
      const prev = i > 0 ? items[i - 1] : null;
      const next = i < items.length - 1 ? items[i + 1] : null;
      const groupStart = prev === null || prev.dir !== it.dir || prev.kind !== it.kind;
      const groupEnd = next === null || next.dir !== it.dir || next.kind !== it.kind;
      if (it.kind === 'msg' && it.msg !== undefined) {
        out.push({ kind: 'msg', msg: it.msg, key: it.key, groupStart: groupStart, groupEnd: groupEnd });
      } else if (it.kind === 'media' && it.media !== undefined) {
        out.push({ kind: 'media', media: it.media, key: it.key, groupStart: groupStart, groupEnd: groupEnd });
      }
    }
    return out;
  }

  /** Push the merged list into the lazy data source; auto-scroll on new items. */
  private pushEntries(): void {
    const entries: ThreadEntry[] = this.buildEntries();
    this.dataSource.setData(entries);
    // Jump to the newest message when new content arrived (or first paint).
    if (entries.length > this.lastCount) {
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 0);
    }
    this.lastCount = entries.length;
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
        .fontColor($r('app.color.ink'))
        .maxLines(3)
    }
    .width(200)
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_CARD)
    .shadow({ radius: 12, color: '#33000000', offsetY: 4 })
  }

  @Builder
  DateChip(label: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.ink_subtle'))
    }
    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
    .backgroundColor($r('app.color.surface_subtle'))
    .borderRadius(Theme.RADIUS_CHIP)
    .alignSelf(ItemAlign.Center)
    .margin({ top: 10, bottom: 6 })
  }

  @Builder
  Bubble(msg: MessageEntry, groupStart: boolean, groupEnd: boolean) {
    Column({ space: 4 }) {
      if (msg.replyTo.length > 0) {
        Text(msg.replyTo)
          .fontSize(12)
          .fontColor($r('app.color.ink_subtle'))
          .maxLines(2)
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }
      Text(msg.text)
        .fontSize(15)
        .fontColor(msg.dir === 'out' ? $r('app.color.bubble_out_text') : $r('app.color.bubble_in_text'))
        .lineHeight(20)
      if (msg.reactions.length > 0) {
        Text(msg.reactions)
          .fontSize(13)
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(Theme.RADIUS_CHIP)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .alignSelf(ItemAlign.End)
      }
      Row({ space: 4 }) {
        Text(msg.time)
          .fontSize(11)
          .fontColor($r('app.color.ink_subtle'))
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
    .backgroundColor(msg.dir === 'out' ? $r('app.color.bubble_out') : $r('app.color.bubble_in'))
    // Tails: asymmetric corner on the last bubble of a sender run.
    .borderRadius(msg.dir === 'out'
      ? { topLeft: Theme.RADIUS_BUBBLE, topRight: groupEnd ? 4 : Theme.RADIUS_BUBBLE, bottomLeft: Theme.RADIUS_BUBBLE, bottomRight: Theme.RADIUS_BUBBLE }
      : { topLeft: groupEnd ? 4 : Theme.RADIUS_BUBBLE, topRight: Theme.RADIUS_BUBBLE, bottomLeft: Theme.RADIUS_BUBBLE, bottomRight: Theme.RADIUS_BUBBLE })
    .alignSelf(msg.dir === 'out' ? ItemAlign.End : ItemAlign.Start)
    // Same-sender runs are tight (1px), groups breathe (10px before, 8px after).
    .margin({
      top: groupStart ? 10 : 1,
      bottom: groupEnd ? 8 : 1
    })
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
  MediaBubble(m: MediaMessage, groupStart: boolean, groupEnd: boolean) {
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
        .fontColor($r('app.color.ink_subtle'))
        .alignSelf(ItemAlign.End)
    }
    .padding(4)
    .backgroundColor(m.dir === 'out' ? $r('app.color.bubble_out') : $r('app.color.bubble_in'))
    .borderRadius(m.dir === 'out'
      ? { topLeft: Theme.RADIUS_BUBBLE, topRight: groupEnd ? 4 : Theme.RADIUS_BUBBLE, bottomLeft: Theme.RADIUS_BUBBLE, bottomRight: Theme.RADIUS_BUBBLE }
      : { topLeft: groupEnd ? 4 : Theme.RADIUS_BUBBLE, topRight: Theme.RADIUS_BUBBLE, bottomLeft: Theme.RADIUS_BUBBLE, bottomRight: Theme.RADIUS_BUBBLE })
    .alignSelf(m.dir === 'out' ? ItemAlign.End : ItemAlign.Start)
    .margin({
      top: groupStart ? 10 : 1,
      bottom: groupEnd ? 8 : 1
    })
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
          .fontColor($r('app.color.ink'))
      } else {
        Text('Loading…')
          .fontSize(14)
          .fontColor($r('app.color.ink_subtle'))
      }
    }
    .width(180)
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor($r('app.color.surface_subtle'))
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
          .fontColor([$r('app.color.ink_faded')])
      }
      .width(180)
      .height(180)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.media_placeholder'))
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
          .fontColor([$r('app.color.ink_faded')])
      }
      .width(180)
      .height(180)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.media_placeholder'))
      .borderRadius(8)
    }
  }

  build() {
    Column() {
      // iOS-style navigation bar.
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.ink')])
          .width(36)
          .onClick(() => {
            this.onBack();
          })

        Stack() {
          Circle({ width: 34, height: 34 })
            .fill($r('app.color.brand'))
          if (this.chatName.length > 0) {
            Text(this.chatName.charAt(0).toUpperCase())
              .fontSize(14)
              .fontColor($r('app.color.brand_text'))
          }
          if (!this.avatarFailed && this.chatName.length > 0) {
            Image(cdpBridge.avatarUrlFor(this.chatName))
              .width(34)
              .height(34)
              .borderRadius(17)
              .onError(() => {
                this.avatarFailed = true;
              })
          }
        }
        .width(34)
        .height(34)
        .margin({ right: 10 })

        Column({ space: 2 }) {
          if (this.chatName.length > 0) {
            Text(cdpBridge.displayName(this.chatName))
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink'))
              .maxLines(1)
          }
          Text('WhatsApp')
            .fontSize(11)
            .fontColor($r('app.color.ink_faded'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        SymbolGlyph($r('sys.symbol.phone'))
          .fontSize(20)
          .fontColor([$r('app.color.ink')])
          .margin({ left: 8 })
          .onClick(() => {
            this.startWhatsAppCall(false);
          })
        SymbolGlyph($r('sys.symbol.video'))
          .fontSize(20)
          .fontColor([$r('app.color.ink')])
          .margin({ left: 16, right: 8 })
          .onClick(() => {
            this.startWhatsAppCall(true);
          })
      }
      .width('100%')
      .height(Theme.HEADER_HEIGHT)
      .padding({ left: 4, right: 8 })
      .backgroundColor($r('app.color.surface'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

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
        .backgroundColor($r('app.color.bg_chat'))
      } else if (this.dataSource.totalCount() === 0) {
        Column({ space: 8 }) {
          Text('No messages')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ink'))
          Text('Messages will appear when the session is active.')
            .fontSize(13)
            .fontColor($r('app.color.ink_subtle'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_chat'))
      } else {
        List({ space: 0, scroller: this.scroller }) {
          LazyForEach(this.dataSource, (entry: Object) => {
            ListItem() {
              if ((entry as ThreadEntry).kind === 'date') {
                Row() {
                  this.DateChip((entry as DateEntry).label)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
              } else if ((entry as ThreadEntry).kind === 'media') {
                Row() {
                  this.MediaBubble((entry as MediaEntry).media,
                    (entry as MediaEntry).groupStart, (entry as MediaEntry).groupEnd)
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
                .justifyContent((entry as MediaEntry).media.dir === 'out' ? FlexAlign.End : FlexAlign.Start)
              } else {
                Row() {
                  this.Bubble((entry as MsgEntry).msg,
                    (entry as MsgEntry).groupStart, (entry as MsgEntry).groupEnd)
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
                .justifyContent((entry as MsgEntry).msg.dir === 'out' ? FlexAlign.End : FlexAlign.Start)
              }
            }
          }, (entry: Object) => (entry as ThreadEntry).key)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.bg_chat'))
        .animation({ duration: Theme.DURATION_FAST, curve: curves.springMotion(0.35, 0.85) })
      }

      // Reply indicator (set by long-pressing a message).
      if (this.replyTargetId.length > 0) {
        Row({ space: 8 }) {
          Text('Replying to: ' + this.replyDraft)
            .fontSize(12)
            .fontColor($r('app.color.ink_subtle'))
            .maxLines(1)
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(14)
            .fontColor([$r('app.color.ink_subtle')])
            .onClick(() => {
              this.replyTargetId = '';
              this.replyDraft = '';
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.surface_subtle'))
      }

      Row({ space: 8 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.paperclip'))
            .fontSize(18)
            .fontColor([$r('app.color.ink_subtle')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(20)
        .enabled(!this.sendingMedia)
        .onClick(() => {
          this.sendMedia('gallery');
        })
        Button() {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(18)
            .fontColor([$r('app.color.ink_subtle')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.surface_subtle'))
        .borderRadius(20)
        .enabled(!this.sendingMedia)
        .onClick(() => {
          this.sendMedia('camera');
        })
        TextInput({ placeholder: 'Message', text: this.draft })
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .fontColor($r('app.color.ink'))
          .placeholderColor($r('app.color.ink_faded'))
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(Theme.RADIUS_FIELD)
          .onChange((v: string) => {
            this.draft = v;
          })
          .onSubmit(() => {
            this.send();
          })
        Button() {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(18)
            .fontColor([$r('app.color.brand_text')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.brand'))
        .borderRadius(20)
        .enabled(!this.sendingMedia)
        .stateStyles({
          pressed: {
            .backgroundColor($r('app.color.brand_pressed'))
          }
        })
        .onClick(() => {
          this.send();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.surface'))
      .border({ width: { top: 0.5 }, color: $r('app.color.divider') })

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
    .backgroundColor($r('app.color.bg_chat'))
  }
}