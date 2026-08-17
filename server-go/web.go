package server

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"

	"go.mau.fi/whatsmeow/types"
)

// b64urlDecode decodes unpadded base64url (matches the Rust server's
// base64::engine::general_purpose::URL_SAFE_NO_PAD).
func b64urlDecode(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(s)
}

// Server bundles the HTTP app + WS.
type Server struct {
	state *AppState
	wa    *WAClient
	mux   *http.ServeMux
}

// NewServer builds the HTTP router (mirrors web.rs::router).
func NewServer(state *AppState, wa *WAClient) *Server {
	s := &Server{state: state, wa: wa, mux: http.NewServeMux()}
	s.routes()
	return s
}

// Mux exposes the HTTP handler for the server.
func (s *Server) Mux() http.Handler { return s.mux }

func (s *Server) routes() {
	// auth-gated handlers
	s.mux.HandleFunc("/status", s.guard(s.status))
	s.mux.HandleFunc("/pair", s.guard(s.pair))
	s.mux.HandleFunc("/pair-code", s.guard(s.pairCode))
	s.mux.HandleFunc("/chats", s.guard(s.chats))
	s.mux.HandleFunc("/messages", s.guard(s.messages))
	s.mux.HandleFunc("/send", s.guard(s.send))
	s.mux.HandleFunc("/send-media", s.guard(s.sendMedia))
	s.mux.HandleFunc("/read", s.guard(s.read))
	s.mux.HandleFunc("/react", s.guard(s.react))
	s.mux.HandleFunc("/logout", s.guard(s.logout))
	s.mux.HandleFunc("/media/", s.guard(s.media))
	s.mux.HandleFunc("/call", s.guard(s.callStart))
	s.mux.HandleFunc("/call/accept", s.guard(s.callAccept))
	s.mux.HandleFunc("/call/reject", s.guard(s.callReject))
	s.mux.HandleFunc("/call/end", s.guard(s.callEnd))
	s.mux.HandleFunc("/call/mute", s.guard(s.callMute))
	s.mux.HandleFunc("/call/camera", s.guard(s.callCamera))
	s.mux.HandleFunc("/call/state", s.guard(s.callState))
	s.mux.HandleFunc("/passkey/request", s.guard(s.passkeyRequest))
	s.mux.HandleFunc("/passkey/assertion", s.guard(s.passkeyAssertion))
	s.mux.HandleFunc("/passkey/confirm", s.guard(s.passkeyConfirm))
	s.mux.HandleFunc("/passkey/cancel", s.guard(s.passkeyCancel))
	s.mux.HandleFunc("/ws", s.guard(s.ws))
}

// guard wraps a handler with the auth check (mirrors web.rs authorized/reject).
func (s *Server) guard(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/ws" {
			log.Printf("REQ %s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)
		}
		if !authorized(r, s.state.Cfg) {
			reject(w)
			return
		}
		h(w, r)
	}
}

// notLinked writes the 403 the Rust server returns when unlinked.
func (s *Server) notLinked(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	w.Write([]byte(`{"error":"not linked"}`))
}

// waOr500 guards handlers that need the live whatsmeow client (nil in tests).
func (s *Server) waOr500(w http.ResponseWriter) bool {
	if s.wa == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "client not initialized"})
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ---- status / pair ----

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"linked": s.state.IsLinked(),
		"phone":  s.state.Phone(),
		"qr":     s.state.QR(),
	})
}

func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	// Restart the QR pairing stream so a fresh code is always available.
	if err := s.wa.StartPairing(r.Context()); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ---- pair-code ----

type pairCodeReq struct {
	Country string `json:"country"`
	Phone   string `json:"phone"`
}

func (s *Server) pairCode(w http.ResponseWriter, r *http.Request) {
	var body pairCodeReq
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	digits := func(x string) string {
		var b strings.Builder
		for _, c := range x {
			if c >= '0' && c <= '9' {
				b.WriteRune(c)
			}
		}
		return b.String()
	}
	country := digits(body.Country)
	phone := digits(body.Phone)
	if country == "" || phone == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "country and phone required"})
		return
	}
	code, err := s.wa.PairCode(r.Context(), country+phone)
	if err != nil {
		log.Printf("pair-code failed: %v", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "code": code})
}

// ---- chats / messages / send / read / react / logout ----

func (s *Server) chats(w http.ResponseWriter, r *http.Request) {
	if !s.state.IsLinked() {
		s.notLinked(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"chats": s.state.Store.Chats()})
}

func (s *Server) messages(w http.ResponseWriter, r *http.Request) {
	if !s.state.IsLinked() {
		s.notLinked(w)
		return
	}
	chat := r.URL.Query().Get("chat")
	if chat == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat required"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": s.state.Store.Messages(chat, 200)})
}

type sendBody struct {
	Chat    string  `json:"chat"`
	Text    string  `json:"text"`
	ReplyTo *string `json:"reply_to"`
}

func (s *Server) send(w http.ResponseWriter, r *http.Request) {
	if !s.state.IsLinked() {
		s.notLinked(w)
		return
	}
	var body sendBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	if body.Chat == "" || body.Text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat and text required"})
		return
	}
	jid, err := types.ParseJID(body.Chat)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad jid: " + err.Error()})
		return
	}
	if s.wa == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "client not initialized"})
		return
	}
	replyTo := ""
	if body.ReplyTo != nil {
		replyTo = *body.ReplyTo
	}
	id, err := s.wa.SendText(r.Context(), jid, body.Text, replyTo)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	// Record the outbound message in the store + broadcast.
	msg := Message{
		ID:      id,
		Chat:    body.Chat,
		Text:    body.Text,
		Dir:     "out",
		Time:    nowMillis(),
		Status:  "sent",
		FromMe:  true,
		ReplyTo: replyTo,
	}
	s.state.Store.UpsertMessage(msg)
	s.state.Bus.Publish(EvMessage(body.Chat))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
}

type chatBody struct {
	Chat string `json:"chat"`
}

func (s *Server) read(w http.ResponseWriter, r *http.Request) {
	if !s.state.IsLinked() {
		s.notLinked(w)
		return
	}
	var body chatBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	jid, err := types.ParseJID(body.Chat)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad jid: " + err.Error()})
		return
	}
	// Mark the latest inbound messages read (mirror the Rust behavior).
	ids := []string{}
	for _, m := range s.state.Store.Messages(body.Chat, 50) {
		if !m.FromMe {
			ids = append(ids, m.ID)
		}
	}
	if len(ids) > 0 {
		if err := s.wa.Client().MarkRead(r.Context(), ids, timeNow(), jid, jid); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
			return
		}
	}
	s.state.Store.MarkRead(body.Chat)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type reactBody struct {
	Chat      string `json:"chat"`
	MessageID string `json:"messageId"`
	Emoji     string `json:"emoji"`
}

func (s *Server) react(w http.ResponseWriter, r *http.Request) {
	if !s.state.IsLinked() {
		s.notLinked(w)
		return
	}
	var body reactBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	jid, err := types.ParseJID(body.Chat)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad jid: " + err.Error()})
		return
	}
	if err := s.wa.React(r.Context(), jid, body.MessageID, body.Emoji); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	s.state.Store.AddReaction(body.Chat, body.MessageID, body.Emoji)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	_ = s.wa.Logout(r.Context())
	s.state.SetPhone("")
	s.state.Store.SetPhone("")
	s.state.Bus.Publish(EvLoggedOut())
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ---- media ----

func (s *Server) sendMedia(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad multipart: " + err.Error()})
		return
	}
	chat := r.FormValue("chat")
	if chat == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat required"})
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "file required"})
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 64<<20))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad jid: " + err.Error()})
		return
	}
	id, err := s.wa.SendMedia(r.Context(), jid, data, header.Filename, header.Header.Get("Content-Type"))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
}

// media serves cached media: /media/{id}/{kind}
func (s *Server) media(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/media/"), "/")
	if len(parts) != 2 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad media path"})
		return
	}
	id, kind := parts[0], parts[1]
	// Serve from the media cache if present; otherwise 404.
	if data, ok := s.state.Media.Get(id, kind); ok {
		w.Header().Set("Content-Type", mediaMime(kind))
		w.Write(data)
		return
	}
	w.WriteHeader(http.StatusNotFound)
}

// ---- calls ----

type callStartBody struct {
	Chat  string `json:"chat"`
	Video bool   `json:"video"`
}

type callIdBody struct {
	CallID string `json:"callId"`
	Video  bool   `json:"video"`
}

func (s *Server) callStart(w http.ResponseWriter, r *http.Request) {
	if !s.state.IsLinked() {
		s.notLinked(w)
		return
	}
	var body callStartBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	callID, err := s.state.Calls.StartOutgoing(r.Context(), s.wa, body.Chat, body.Video)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "callId": callID})
}

func (s *Server) callAccept(w http.ResponseWriter, r *http.Request) {
	var body callIdBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	callID, err := s.state.Calls.AcceptIncoming(r.Context(), s.wa, body.CallID, body.Video)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "callId": callID})
}

func (s *Server) callReject(w http.ResponseWriter, r *http.Request) {
	var body callIdBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	if err := s.state.Calls.RejectIncoming(r.Context(), s.wa, body.CallID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) callEnd(w http.ResponseWriter, r *http.Request) {
	var body callIdBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	if err := s.state.Calls.Hangup(r.Context(), s.wa, body.CallID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type callMuteBody struct {
	CallID string `json:"callId"`
	Muted  bool   `json:"muted"`
}

func (s *Server) callMute(w http.ResponseWriter, r *http.Request) {
	var body callMuteBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	s.state.Calls.SetMuted(body.CallID, body.Muted)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type callCameraBody struct {
	CallID string `json:"callId"`
	On     bool   `json:"on"`
}

func (s *Server) callCamera(w http.ResponseWriter, r *http.Request) {
	var body callCameraBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	s.state.Calls.SetCamera(body.CallID, body.On)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) callState(w http.ResponseWriter, r *http.Request) {
	calls := s.state.Calls.List()
	writeJSON(w, http.StatusOK, map[string]any{"calls": calls, "active": len(calls)})
}

// ---- passkey ----

func (s *Server) passkeyRequest(w http.ResponseWriter, r *http.Request) {
	opts, ok := s.state.TakePasskeyPending()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no pending passkey request"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"options": opts})
}

type passkeyAssertionBody struct {
	CredentialID  string `json:"credentialId"`
	AssertionJSON string `json:"assertionJson"`
}

func (s *Server) passkeyAssertion(w http.ResponseWriter, r *http.Request) {
	var body passkeyAssertionBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	// Decode base64url (no padding) → bytes.
	credID, err := b64urlDecode(body.CredentialID)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad credentialId: " + err.Error()})
		return
	}
	assertionJSON, err := b64urlDecode(body.AssertionJSON)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad assertionJson: " + err.Error()})
		return
	}
	ch := s.state.TakePasskeyAnswer()
	if ch == nil {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "no pending passkey request"})
		return
	}
	select {
	case ch <- PasskeyAnswer{Assertion: &PasskeyAssertion{CredentialID: credID, AssertionJSON: assertionJSON}}:
	default:
		writeJSON(w, http.StatusConflict, map[string]any{"error": "passkey request no longer pending"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) passkeyConfirm(w http.ResponseWriter, r *http.Request) {
	if err := s.wa.PasskeyConfirm(r.Context()); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) passkeyCancel(w http.ResponseWriter, r *http.Request) {
	s.state.TakePasskeyPending()
	if ch := s.state.TakePasskeyAnswer(); ch != nil {
		select {
		case ch <- PasskeyAnswer{Cancelled: true}:
		default:
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
