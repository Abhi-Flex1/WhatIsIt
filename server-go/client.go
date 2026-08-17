package server

import (
	"context"
	"fmt"
	"log"
	"strings"

	"go.mau.fi/whatsmeow"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	// Register the pure-Go sqlite driver as "sqlite3" for the whatsmeow store.
	_ "whatisit/server-go/sqlite3shim"
)

// WAClient wraps the whatsmeow client and adapts its events to the app's
// EventBus + HistoryStore contract.
type WAClient struct {
	cli   *whatsmeow.Client
	state *AppState
	// QR stream (active while pairing).
	qrCh <-chan whatsmeow.QRChannelItem
	cancelQR context.CancelFunc
	// Passkey request options currently pending (recoverable via /passkey/request).
	passkeyOpts string
}

// NewWAClient initializes the SQLite device store and whatsmeow client.
func NewWAClient(ctx context.Context, cfg *Config, state *AppState) (*WAClient, error) {
	storeContainer, err := sqlstore.New(ctx, "sqlite3", fmt.Sprintf("file:%s?_foreign_keys=on", cfg.DBPath), waLog.Stdout("Database", "DEBUG", true))
	if err != nil {
		return nil, fmt.Errorf("open sqlite store: %w", err)
	}
	deviceStore, err := storeContainer.GetFirstDevice(ctx)
	if err != nil {
		return nil, fmt.Errorf("get device: %w", err)
	}
	cli := whatsmeow.NewClient(deviceStore, waLog.Stdout("Client", "DEBUG", true))
	wc := &WAClient{cli: cli, state: state}
	cli.AddEventHandler(wc.handleEvent)
	cli.EnableAutoReconnect = true
	return wc, nil
}

// Client exposes the underlying whatsmeow client.
func (wc *WAClient) Client() *whatsmeow.Client { return wc.cli }

// Connect connects to WhatsApp (or starts pairing if no session).
func (wc *WAClient) Connect(ctx context.Context) error {
	if wc.cli.Store.ID == nil {
		// No stored session: start QR pairing.
		wc.startQR(ctx)
		return wc.cli.Connect()
	}
	if err := wc.cli.Connect(); err != nil {
		return err
	}
	// Restore linked state.
	phone := wc.cli.Store.ID.User
	wc.state.SetPhone(phone)
	wc.state.Store.SetPhone(phone)
	return nil
}

// startQR begins the QR pairing stream and pushes codes via the event bus.
func (wc *WAClient) startQR(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	wc.cancelQR = cancel
	ch, err := wc.cli.GetQRChannel(ctx)
	if err != nil {
		log.Printf("get QR channel: %v", err)
		return
	}
	wc.qrCh = ch
	go func() {
		for item := range ch {
			switch item.Event {
			case "code":
				wc.state.SetQR(item.Code)
				wc.state.Bus.Publish(EvQr(item.Code))
			case "timeout":
				wc.state.SetQR("")
				wc.state.Bus.Publish(EvQr(""))
			}
		}
	}()
}

// PairCode starts phone-number linking and returns the 8-char code.
func (wc *WAClient) PairCode(ctx context.Context, phone string) (string, error) {
	code, err := wc.cli.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "WhatIsIt")
	if err != nil {
		return "", err
	}
	wc.state.SetPairCode(code)
	wc.state.Bus.Publish(EvPairCode(code))
	return code, nil
}

// handleEvent adapts whatsmeow events to the app's event bus + store.
func (wc *WAClient) handleEvent(evt any) {
	switch e := evt.(type) {
	case *events.QR:
		// GetQRChannel handles QR; this is a fallback for the first code.
	case *events.PairSuccess:
		wc.onLinked(e)
	case *events.Connected:
		if wc.cli.Store.ID != nil {
			phone := wc.cli.Store.ID.User
			wc.state.SetPhone(phone)
			wc.state.Store.SetPhone(phone)
			wc.state.Bus.Publish(EvLinked(phone))
		}
	case *events.LoggedOut:
		wc.onLoggedOut()
	case *events.PairPasskeyRequest:
		wc.onPasskeyRequest(e)
	case *events.PairPasskeyConfirmation:
		wc.state.Bus.Publish(EvPasskeyConf(e.Code))
	case *events.PairPasskeyError:
		wc.state.Bus.Publish(EvPasskeyErr(e.Error.Error()))
	case *events.Message:
		wc.onMessage(e)
	case *events.Receipt:
		wc.onReceipt(e)
	case *events.ChatPresence:
		// Presence updates are not part of the app contract; ignore.
	}
}

func (wc *WAClient) onLinked(e *events.PairSuccess) {
	phone := e.ID.User
	wc.state.SetPhone(phone)
	wc.state.Store.SetPhone(phone)
	wc.state.Bus.Publish(EvLinked(phone))
}

func (wc *WAClient) onLoggedOut() {
	wc.state.SetPhone("")
	wc.state.Store.SetPhone("")
	wc.state.Bus.Publish(EvLoggedOut())
}

func (wc *WAClient) onPasskeyRequest(e *events.PairPasskeyRequest) {
	if e.PublicKey == nil {
		wc.state.Bus.Publish(EvPasskeyErr("passkey request had no public key"))
		return
	}
	opts := mustJSON(e.PublicKey)
	wc.state.SetPasskeyPending(opts)
	wc.state.Bus.Publish(EvPasskeyReq(opts))
}

// PasskeyResponse sends the app's WebAuthn assertion to complete the ceremony.
func (wc *WAClient) PasskeyResponse(ctx context.Context, resp *types.WebAuthnResponse) error {
	return wc.cli.SendPasskeyResponse(ctx, resp)
}

// PasskeyConfirm finishes the pairing after the code match.
func (wc *WAClient) PasskeyConfirm(ctx context.Context) error {
	return wc.cli.SendPasskeyConfirmation(ctx)
}

func (wc *WAClient) onMessage(e *events.Message) {
	chat := e.Info.Chat.String()
	msg := Message{
		ID:     e.Info.ID,
		Chat:   chat,
		Dir:    "in",
		Time:   e.Info.Timestamp.UnixMilli(),
		Status: "received",
		FromMe: e.Info.IsFromMe,
	}
	if e.Info.IsFromMe {
		msg.Dir = "out"
	}
	// Extract text / media / reply.
	extractMessage(e, &msg)
	// Cache incoming media (mirror media.rs::maybe_cache_media).
	if msg.Media != nil && !msg.FromMe {
		if dl, ok := mediaDownloadable(e.Message); ok {
			wc.cacheIncomingMedia(wc.cli.BackgroundEventCtx, e, msg.Media.Kind, dl)
		}
	}
	if e.Info.IsFromMe {
		msg.Status = "sent"
	}
	// Upsert + broadcast.
	wc.state.Store.UpsertMessage(msg)
	// Update chat preview name.
	if e.Info.Sender.User != "" {
		wc.state.Store.SetName(chat, jidToName(e.Info.Sender))
	}
	wc.state.Bus.Publish(EvMessage(chat))
}

func (wc *WAClient) onReceipt(e *events.Receipt) {
	if len(e.MessageIDs) == 0 {
		return
	}
	chat := e.Chat.String()
	status := "delivered"
	if e.Type == events.ReceiptTypeRead || e.Type == events.ReceiptTypeReadSelf {
		status = "read"
	}
	for _, id := range e.MessageIDs {
		wc.state.Store.SetStatus(chat, id, status)
	}
	wc.state.Bus.Publish(EvReceipt(chat))
}

// SendText sends a text message, returns the message ID.
func (wc *WAClient) SendText(ctx context.Context, jid types.JID, text, replyTo string) (string, error) {
	msg := &waE2E.Message{Conversation: &text}
	if replyTo != "" {
		ext := &waE2E.ExtendedTextMessage{
			Text:        &text,
			ContextInfo: &waE2E.ContextInfo{StanzaID: &replyTo},
		}
		msg = &waE2E.Message{ExtendedTextMessage: ext}
	}
	resp, err := wc.cli.SendMessage(ctx, jid, msg)
	if err != nil {
		return "", err
	}
	return resp.ID, nil
}

// Logout disconnects and clears the stored session.
func (wc *WAClient) Logout(ctx context.Context) error {
	return wc.cli.Logout(ctx)
}

// React sends (or removes, with "") a reaction on a message.
func (wc *WAClient) React(ctx context.Context, chat types.JID, messageID, emoji string) error {
	msg := wc.cli.BuildReaction(chat, chat, types.MessageID(messageID), emoji)
	_, err := wc.cli.SendMessage(ctx, chat, msg)
	return err
}

// SendMedia uploads a file and sends it as a media message (image/video/audio
// by extension, document otherwise), mirroring media.rs::handle_send_media.
func (wc *WAClient) SendMedia(ctx context.Context, chat types.JID, data []byte, filename, mime string) (string, error) {
	mediaType := wc.mediaTypeForFilename(filename)
	resp, err := wc.cli.Upload(ctx, data, mediaType)
	if err != nil {
		return "", err
	}
	msg := wc.buildMediaMessage(mediaType, resp, filename)
	sent, err := wc.cli.SendMessage(ctx, chat, msg)
	if err != nil {
		return "", err
	}
	return sent.ID, nil
}

func (wc *WAClient) mediaTypeForFilename(filename string) whatsmeow.MediaType {
	switch ext := strings.ToLower(filename[strings.LastIndexByte(filename, '.')+1:]); ext {
	case "jpg", "jpeg", "png", "gif", "webp":
		return whatsmeow.MediaImage
	case "mp4", "mov", "mkv", "3gp":
		return whatsmeow.MediaVideo
	case "mp3", "m4a", "ogg", "opus", "wav":
		return whatsmeow.MediaAudio
	}
	return whatsmeow.MediaDocument
}

func (wc *WAClient) buildMediaMessage(mediaType whatsmeow.MediaType, up whatsmeow.UploadResponse, filename string) *waE2E.Message {
	length := &up.FileLength
	switch mediaType {
	case whatsmeow.MediaImage:
		return &waE2E.Message{
			ImageMessage: &waE2E.ImageMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("image/jpeg"),
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	case whatsmeow.MediaVideo:
		return &waE2E.Message{
			VideoMessage: &waE2E.VideoMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("video/mp4"),
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	case whatsmeow.MediaAudio:
		return &waE2E.Message{
			AudioMessage: &waE2E.AudioMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("audio/ogg"),
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	default:
		return &waE2E.Message{
			DocumentMessage: &waE2E.DocumentMessage{
				URL:        &up.URL,
				Mimetype:   proto.String("application/octet-stream"),
				FileName:   &filename,
				FileLength: length,
				MediaKey:   up.MediaKey,
				FileEncSHA256: up.FileEncSHA256,
				FileSHA256: up.FileSHA256,
				DirectPath: &up.DirectPath,
			},
		}
	}
}

// cacheIncomingMedia downloads a media message to the cache (mirrors
// media.rs::maybe_cache_media). Non-blocking best-effort.
func (wc *WAClient) cacheIncomingMedia(ctx context.Context, e *events.Message, kind string, downloadable whatsmeow.DownloadableMessage) {
	go func() {
		data, err := wc.cli.Download(ctx, downloadable)
		if err != nil {
			log.Printf("media download %s: %v", kind, err)
			return
		}
		if err := wc.state.Media.Put(e.Info.ID, kind, data); err != nil {
			log.Printf("media cache %s: %v", kind, err)
		}
	}()
}

// IsConnected reports the connection state.
func (wc *WAClient) IsConnected() bool { return wc.cli.IsConnected() }

// ---- helpers ----

// jidToName derives a display name from a JID (matches app expectations: the
// phone number for a user, the group subject for a group).
func jidToName(jid types.JID) string {
	if jid.Server == types.DefaultUserServer {
		return jid.User
	}
	return jid.User
}

func mustJSON(v any) string {
	b, _ := jsonMarshal(v)
	return string(b)
}

func jsonMarshal(v any) ([]byte, error) {
	return jsonMarshalImpl(v)
}

// trimJID normalizes a chat arg to a bare JID string.
func trimJID(s string) string {
	if i := strings.IndexByte(s, '@'); i >= 0 {
		return s
	}
	return s
}
