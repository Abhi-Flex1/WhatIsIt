package server

import (
	"encoding/json"
	"net/http"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
)

// postStatus publishes a text status update (the WhatsApp "My status"
// broadcast), mirroring the send flow in client.go::SendText.
func (s *Server) postStatus(w http.ResponseWriter, r *http.Request) {
	if !s.wa.IsConnected() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "client not connected"})
		return
	}
	var body struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad request"})
		return
	}
	text := body.Text
	if text == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "text required"})
		return
	}
	msg := &waE2E.Message{Conversation: &text}
	resp, err := s.wa.cli.SendMessage(r.Context(), types.StatusBroadcastJID, msg)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": resp.ID})
}