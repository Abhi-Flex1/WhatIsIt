package adapter

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

func (a *Adapter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/status":
		a.handleStatus(w, r)
	case "/pair":
		a.handlePair(w, r)
	case "/pair-code":
		a.handlePairCode(w, r)
	case "/chats":
		a.handleChats(w, r)
	case "/messages":
		a.handleMessages(w, r)
	case "/send":
		a.handleSend(w, r)
	case "/send-media":
		a.handleSendMedia(w, r)
	case "/read":
		a.handleRead(w, r)
	case "/react":
		a.handleReact(w, r)
	case "/logout":
		a.handleLogout(w, r)
	case "/call":
		a.handleCall(w, r)
	case "/call/accept":
		a.handleCallAccept(w, r)
	case "/call/reject":
		a.handleCallReject(w, r)
	case "/call/end":
		a.handleCallEnd(w, r)
	case "/call/mute":
		a.handleCallMute(w, r)
	case "/call/camera":
		a.handleCallCamera(w, r)
	case "/call/state":
		a.handleCallState(w, r)
	case "/passkey/request":
		a.handlePasskeyRequest(w, r)
	case "/passkey/assertion":
		a.handlePasskeyAssertion(w, r)
	case "/passkey/confirm":
		a.handlePasskeyConfirm(w, r)
	case "/passkey/cancel":
		a.handlePasskeyCancel(w, r)
	case "/config/backend":
		a.handleConfigBackend(w, r)
	case "/provision/qr":
		a.handleProvisionQR(w, r)
	default:
		if strings.HasPrefix(r.URL.Path, "/media/") {
			a.handleMedia(w, r)
			return
		}
		http.NotFound(w, r)
	}
}

func (a *Adapter) handleStatus(w http.ResponseWriter, r *http.Request) {
	path := a.instancePath("/status")
	b, status, err := a.proxyToWhatsMiau(r.Method, path, nil)
	if err != nil {
		log.Printf("status proxy error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status == http.StatusNotFound {
		writeJSON(w, http.StatusOK, map[string]any{
			"linked": false,
			"phone":  "",
			"qr":     a.store.QR(),
		})
		return
	}
	var resp map[string]any
	if err := json.Unmarshal(b, &resp); err != nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"linked": false,
			"phone":  "",
			"qr":     a.store.QR(),
		})
		return
	}
	state := ""
	if inst, ok := resp["instance"].(map[string]any); ok {
		state = fmt.Sprintf("%v", inst["state"])
	} else {
		state = fmt.Sprintf("%v", resp["state"])
	}
	linked := state == "open"
	phone := ""
	if linked {
		phone = a.store.Phone()
		if phone == "" {
			phone = a.getString(resp, "ownerJid")
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"linked": linked,
		"phone":  phone,
		"qr":     a.store.QR(),
	})
}

func (a *Adapter) handlePair(w http.ResponseWriter, r *http.Request) {
	path := a.instancePath("/connect")
	b, status, err := a.proxyToWhatsMiau(r.Method, path, nil)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status == http.StatusOK {
		var resp map[string]any
		if json.Unmarshal(b, &resp) == nil {
			if qr, ok := resp["base64"].(string); ok && qr != "" {
				qrCode := qr
				if strings.HasPrefix(qrCode, "data:image/png;base64,") {
					qrCode = strings.TrimPrefix(qrCode, "data:image/png;base64,")
				}
				a.store.SetQR(qrCode)
				a.hub.Broadcast(BackendEvent{Type: EventQR, QR: qrCode})
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handlePairCode(w http.ResponseWriter, r *http.Request) {
	var body map[string]string
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	country := a.digits(body["country"])
	phone := a.digits(body["phone"])
	if country == "" || phone == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "country and phone required"})
		return
	}
	reqBody, _ := json.Marshal(map[string]string{
		"id":     a.getInstanceName(),
		"number": country + phone,
	})
	path := a.instancePath("/connect")
	b, status, err := a.proxyToWhatsMiau("POST", path, reqBody)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status != http.StatusOK {
		writeJSON(w, status, b)
		return
	}
	var resp map[string]any
	if err := json.Unmarshal(b, &resp); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "pair-code failed"})
		return
	}
	code := ""
	if c, ok := resp["pairingCode"].(string); ok {
		code = c
	}
	if code != "" {
		a.store.SetPairCode(code)
		a.hub.Broadcast(BackendEvent{Type: EventPairCode, Code: code})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "code": code})
}

func (a *Adapter) handleChats(w http.ResponseWriter, r *http.Request) {
	chats := a.store.Chats()
	writeJSON(w, http.StatusOK, map[string]any{"chats": chats})
}

func (a *Adapter) handleMessages(w http.ResponseWriter, r *http.Request) {
	chat := r.URL.Query().Get("chat")
	if chat == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat required"})
		return
	}
	messages := a.store.Messages(chat, 200)
	writeJSON(w, http.StatusOK, map[string]any{"messages": messages})
}

func (a *Adapter) handleSend(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	chat, _ := body["chat"].(string)
	text, _ := body["text"].(string)
	if chat == "" || text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat and text required"})
		return
	}
	reqBody, _ := json.Marshal(map[string]any{
		"number": chat,
		"text":   text,
	})
	if replyTo, ok := body["replyTo"].(string); ok && replyTo != "" {
		reqBody, _ = json.Marshal(map[string]any{
			"number": chat,
			"text":   text,
			"quoted": map[string]any{
				"key":     map[string]string{"id": replyTo},
				"message": map[string]string{"conversation": text},
			},
		})
	}
	b, status, err := a.proxyToWhatsMiau("POST", a.messagePath("/text"), reqBody)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status != http.StatusOK {
		writeJSON(w, status, b)
		return
	}
	var resp map[string]any
	if err := json.Unmarshal(b, &resp); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "invalid response"})
		return
	}
	msgID := a.getMessageID(resp)
	msg := Message{
		ID:     msgID,
		Chat:   chat,
		Text:   text,
		Dir:    "out",
		Time:   timeNow(),
		Status: "sent",
		FromMe: true,
	}
	a.store.UpsertMessage(msg)
	a.hub.Broadcast(BackendEvent{Type: EventMessage, Chat: chat})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": msgID})
}

func (a *Adapter) getMessageID(resp map[string]any) string {
	if key, ok := resp["key"].(map[string]any); ok {
		if id, ok := key["id"].(string); ok {
			return id
		}
	}
	return ""
}

func (a *Adapter) handleSendMedia(w http.ResponseWriter, r *http.Request) {
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
	mime := header.Header.Get("Content-Type")
	filename := header.Filename
	mediatype := "document"
	if strings.HasPrefix(mime, "image/") {
		mediatype = "image"
	} else if strings.HasPrefix(mime, "video/") {
		mediatype = "video"
	} else if strings.HasPrefix(mime, "audio/") {
		mediatype = "audio"
	}
	a.ensureDir(a.mediaDir)
	localPath := a.mediaDir + "/" + filename
	_ = os.WriteFile(localPath, data, 0o644)
	mediaURL := a.mediaPublicURL + "/" + filename
	reqBody, _ := json.Marshal(map[string]any{
		"number":    chat,
		"mediatype": mediatype,
		"media":     mediaURL,
		"fileName":  filename,
		"mimetype":  mime,
	})
	b, status, err := a.proxyToWhatsMiau("POST", a.messagePath("/sendMedia"), reqBody)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status != http.StatusOK {
		writeJSON(w, status, b)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handleRead(w http.ResponseWriter, r *http.Request) {
	var body map[string]string
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	chat := body["chat"]
	if chat == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat required"})
		return
	}
	ids := []string{}
	for _, m := range a.store.Messages(chat, 50) {
		if !m.FromMe {
			ids = append(ids, m.ID)
		}
	}
	if len(ids) > 0 {
		reqBody, _ := json.Marshal(map[string]any{
			"readMessages": []map[string]any{
				{"remoteJid": chat, "messageIds": ids},
			},
		})
		a.proxyToWhatsMiau("POST", a.chatPath("/read-messages"), reqBody)
	}
	a.store.MarkRead(chat)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handleReact(w http.ResponseWriter, r *http.Request) {
	var body map[string]string
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	chat := body["chat"]
	messageID := body["messageId"]
	emoji := body["emoji"]
	if chat == "" || messageID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "chat and messageId required"})
		return
	}
	reqBody, _ := json.Marshal(map[string]any{
		"reaction": emoji,
		"key": map[string]any{
			"remoteJid": chat,
			"id":        messageID,
			"fromMe":    true,
		},
	})
	a.proxyToWhatsMiau("POST", a.messagePath("/sendReaction"), reqBody)
	a.store.AddReaction(chat, messageID, emoji)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handleLogout(w http.ResponseWriter, r *http.Request) {
	a.proxyToWhatsMiau("DELETE", a.instancePath("/logout"), nil)
	a.store.SetPhone("")
	a.hub.Broadcast(BackendEvent{Type: EventLoggedOut})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handleCall(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]any{"error": "calls not supported via adapter"})
}
func (a *Adapter) handleCallAccept(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]any{"error": "calls not supported via adapter"})
}
func (a *Adapter) handleCallReject(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]any{"error": "calls not supported via adapter"})
}
func (a *Adapter) handleCallEnd(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]any{"error": "calls not supported via adapter"})
}
func (a *Adapter) handleCallMute(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]any{"error": "calls not supported via adapter"})
}
func (a *Adapter) handleCallCamera(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]any{"error": "calls not supported via adapter"})
}
func (a *Adapter) handleCallState(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"calls": []any{}, "active": 0})
}

func (a *Adapter) handlePasskeyRequest(w http.ResponseWriter, r *http.Request) {
	path := a.instancePath("/connectionState")
	b, status, err := a.proxyToWhatsMiau("GET", path, nil)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status != http.StatusOK {
		writeJSON(w, status, b)
		return
	}
	var resp map[string]any
	if err := json.Unmarshal(b, &resp); err != nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no pending passkey request"})
		return
	}
	state := ""
	if inst, ok := resp["instance"].(map[string]any); ok {
		state = fmt.Sprintf("%v", inst["state"])
	} else {
		state = fmt.Sprintf("%v", resp["state"])
	}
	if state != "pairing_passkey" {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no pending passkey request"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"options": a.store.QR()})
}

func (a *Adapter) handlePasskeyAssertion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
func (a *Adapter) handlePasskeyConfirm(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
func (a *Adapter) handlePasskeyCancel(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handleConfigBackend(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"adapter_url":   "http://" + a.listenAddr,
		"instance_id":   a.getInstanceName(),
		"whatsmiau_url": a.whatsMiau,
		"features": map[string]any{
			"calls":         false,
			"passkey":       true,
			"media_proxy":   true,
			"webhooks":      true,
			"auto_discover": true,
			"provisioning":  true,
		},
	})
}

func (a *Adapter) handleProvisionQR(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Query().Get("host")
	port := r.URL.Query().Get("port")
	if host == "" {
		host = a.getInstanceName()
	}
	if port == "" {
		port = "18770"
	}
	provisionURL := fmt.Sprintf("%s://%s?host=%s&port=%s", "whatisit", "provision", host, port)
	writeJSON(w, http.StatusOK, map[string]any{
		"provision_url": provisionURL,
		"backend_host":  host,
		"backend_port":  port,
		"adapter_url":   "http://" + a.listenAddr,
	})
}

func (a *Adapter) handleMedia(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/media/"), "/")
	if len(parts) != 2 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad media path"})
		return
	}
	path := fmt.Sprintf("/v1/instance/%s/message/media?messageId=%s&type=%s", a.getInstanceName(), parts[0], parts[1])
	b, status, err := a.proxyToWhatsMiau("GET", path, nil)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if status != http.StatusOK {
		w.WriteHeader(status)
		return
	}
	w.Header().Set("Content-Type", detectContentType(b))
	w.Write(b)
}

func (a *Adapter) handleFileServe(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/files/")
	if name == "" {
		http.NotFound(w, r)
		return
	}
	path := a.mediaDir + "/" + name
	b, err := os.ReadFile(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", detectContentType(b))
	w.Write(b)
}

func detectContentType(b []byte) string {
	if len(b) > 12 && string(b[:4]) == "\x89PNG" {
		return "image/png"
	}
	if len(b) > 2 && string(b[:2]) == "\xff\xd8" {
		return "image/jpeg"
	}
	if len(b) > 4 && string(b[:4]) == "RIFF" && len(b) > 8 && string(b[8:12]) == "WEBP" {
		return "image/webp"
	}
	if len(b) > 4 && string(b[:4]) == "OggS" {
		return "audio/ogg"
	}
	if len(b) > 12 && string(b[4:12]) == "ftypmp42" {
		return "video/mp4"
	}
	if len(b) > 4 && string(b[:4]) == "%PDF" {
		return "application/pdf"
	}
	return "application/octet-stream"
}

func (a *Adapter) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var event map[string]any
	if err := json.NewDecoder(r.Body).Decode(&event); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	eventType, _ := event["event"].(string)
	data, _ := event["data"].(map[string]any)
	switch eventType {
	case "messages.upsert":
		a.handleMessageUpsert(data)
	case "messages.update":
		a.handleMessageUpdate(data)
	case "messages.delete":
		a.handleMessageDelete(data)
	case "contacts.upsert":
		a.handleContactsUpsert(data)
	case "connection.update":
		a.handleConnectionUpdate(data)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (a *Adapter) handleMessageUpsert(data map[string]any) {
	msg, ok := data["message"].(map[string]any)
	if !ok {
		return
	}
	key, _ := msg["key"].(map[string]any)
	remoteJid, _ := key["remoteJid"].(string)
	id, _ := key["id"].(string)
	fromMe := false
	if fm, ok := key["fromMe"].(bool); ok {
		fromMe = fm
	}
	pushName := a.getString(data, "pushName")
	messageTimestamp := int64(0)
	if ts, ok := data["messageTimestamp"].(float64); ok {
		messageTimestamp = int64(ts)
	}
	text := ""
	media := (*MediaRef)(nil)
	if conv, ok := msg["conversation"].(string); ok {
		text = conv
	} else if ext, ok := msg["extendedTextMessage"].(map[string]any); ok {
		text, _ = ext["text"].(string)
	} else if img, ok := msg["imageMessage"].(map[string]any); ok {
		media = &MediaRef{
			Kind:     "image",
			URL:      a.getString(img, "url"),
			ThumbURL: a.getString(img, "jpegThumbnail"),
			Caption:  a.getString(img, "caption"),
			Mime:     a.getString(img, "mimetype"),
		}
	} else if vid, ok := msg["videoMessage"].(map[string]any); ok {
		media = &MediaRef{
			Kind:     "video",
			URL:      a.getString(vid, "url"),
			ThumbURL: a.getString(vid, "jpegThumbnail"),
			Caption:  a.getString(vid, "caption"),
			Mime:     a.getString(vid, "mimetype"),
		}
	} else if aud, ok := msg["audioMessage"].(map[string]any); ok {
		media = &MediaRef{
			Kind: "audio",
			URL:  a.getString(aud, "url"),
			Mime: a.getString(aud, "mimetype"),
		}
	} else if doc, ok := msg["documentMessage"].(map[string]any); ok {
		media = &MediaRef{
			Kind:    "document",
			URL:     a.getString(doc, "url"),
			Caption: a.getString(doc, "caption"),
			Mime:    a.getString(doc, "mimetype"),
		}
	} else if sticker, ok := msg["stickerMessage"].(map[string]any); ok {
		media = &MediaRef{
			Kind: "sticker",
			URL:  a.getString(sticker, "url"),
			Mime: a.getString(sticker, "mimetype"),
		}
	}
	if !fromMe {
		a.store.BumpUnread(remoteJid)
	}
	a.store.SetName(remoteJid, pushName)
	message := Message{
		ID:     id,
		Chat:   remoteJid,
		Text:   text,
		Dir:    "in",
		Time:   messageTimestamp,
		Status: "received",
		Media:  media,
		FromMe: fromMe,
	}
	if fromMe {
		message.Dir = "out"
		message.Status = "sent"
	}
	a.store.UpsertMessage(message)
	a.hub.Broadcast(BackendEvent{Type: EventMessage, Chat: remoteJid})
}

func (a *Adapter) handleMessageUpdate(data map[string]any) {
	key, _ := data["key"].(map[string]any)
	remoteJid, _ := key["remoteJid"].(string)
	messageID, _ := key["id"].(string)
	status := "delivered"
	if s, ok := data["status"].(string); ok {
		status = s
	}
	if status == "read" {
		status = "read"
	}
	a.store.SetStatus(remoteJid, messageID, status)
	a.hub.Broadcast(BackendEvent{Type: EventReceipt, Chat: remoteJid})
}

func (a *Adapter) handleMessageDelete(data map[string]any) {}

func (a *Adapter) handleContactsUpsert(data map[string]any) {
	a.hub.Broadcast(BackendEvent{Type: EventChats})
}

func (a *Adapter) handleConnectionUpdate(data map[string]any) {
	state, _ := data["state"].(string)
	switch state {
	case "open":
		phone := a.getString(data, "wuid")
		a.store.SetPhone(phone)
		a.hub.Broadcast(BackendEvent{Type: EventLinked, Phone: phone, Linked: true})
	case "close":
		a.store.SetPhone("")
		a.hub.Broadcast(BackendEvent{Type: EventLoggedOut})
	}
}

func (a *Adapter) Run(ctx context.Context, listenAddr string) error {
	a.listenAddr = listenAddr
	if a.mediaPublicURL == "" {
		a.mediaPublicURL = "http://localhost:18770/files"
	}
	if err := a.ensureInstance(ctx); err != nil {
		return fmt.Errorf("ensure instance: %w", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/status", a.handleStatus)
	mux.HandleFunc("/pair", a.handlePair)
	mux.HandleFunc("/pair-code", a.handlePairCode)
	mux.HandleFunc("/chats", a.handleChats)
	mux.HandleFunc("/messages", a.handleMessages)
	mux.HandleFunc("/send", a.handleSend)
	mux.HandleFunc("/send-media", a.handleSendMedia)
	mux.HandleFunc("/read", a.handleRead)
	mux.HandleFunc("/react", a.handleReact)
	mux.HandleFunc("/logout", a.handleLogout)
	mux.HandleFunc("/call", a.handleCall)
	mux.HandleFunc("/call/accept", a.handleCallAccept)
	mux.HandleFunc("/call/reject", a.handleCallReject)
	mux.HandleFunc("/call/end", a.handleCallEnd)
	mux.HandleFunc("/call/mute", a.handleCallMute)
	mux.HandleFunc("/call/camera", a.handleCallCamera)
	mux.HandleFunc("/call/state", a.handleCallState)
	mux.HandleFunc("/passkey/request", a.handlePasskeyRequest)
	mux.HandleFunc("/passkey/assertion", a.handlePasskeyAssertion)
	mux.HandleFunc("/passkey/confirm", a.handlePasskeyConfirm)
	mux.HandleFunc("/passkey/cancel", a.handlePasskeyCancel)
	mux.HandleFunc("/media/", a.handleMedia)
	mux.HandleFunc("/files/", a.handleFileServe)
	mux.HandleFunc("/ws", a.hub.ServeHTTP)
	mux.HandleFunc("/webhook/whatsmiau", a.handleWebhook)

	server := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		a.flushStore()
	}()

	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				a.flushStore()
			case <-ctx.Done():
				return
			}
		}
	}()

	log.Printf("adapter listening on %s (instance=%s, whatsMiau=%s)", listenAddr, a.getInstanceName(), a.whatsMiau)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}

func (a *Adapter) ensureInstance(ctx context.Context) error {
	name := a.getInstanceName()
	path := fmt.Sprintf("/v1/instance/%s/status", name)
	b, status, err := a.proxyToWhatsMiau("GET", path, nil)
	if err != nil {
		return err
	}
	if status == http.StatusOK {
		return nil
	}
	if status == http.StatusNotFound {
		createBody, _ := json.Marshal(map[string]string{
			"id":           name,
			"instanceName": name,
		})
		b, status, err := a.proxyToWhatsMiau("POST", "/v1/instance/create", createBody)
		if err != nil {
			return err
		}
		if status != http.StatusCreated && status != http.StatusOK {
			return fmt.Errorf("create instance failed: %d %s", status, string(b))
		}
		webhookURL := fmt.Sprintf("http://%s/webhook/whatsmiau", a.listenAddr)
		webhookBody, _ := json.Marshal(map[string]any{
			"instanceId": name,
			"webhook": map[string]any{
				"enabled":  true,
				"url":      webhookURL,
				"base64":   false,
				"byEvents": false,
				"events":   []string{"messages.upsert", "messages.update", "messages.delete", "contacts.upsert", "connection.update"},
			},
		})
		b, status, err = a.proxyToWhatsMiau("POST", fmt.Sprintf("/v1/webhook/set/%s", name), webhookBody)
		if err != nil {
			log.Printf("webhook set failed: %v", err)
		} else {
			log.Printf("webhook set response: %d %s", status, string(b))
		}
		return nil
	}
	return fmt.Errorf("unexpected status checking instance: %d", status)
}
