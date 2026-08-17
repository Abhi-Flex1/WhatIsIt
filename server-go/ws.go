package server

import (
	"encoding/binary"
	"log"
	"net/http"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// The app connects from the device; allow all origins (the Rust server
	// does no origin check).
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ws mirrors web.rs::ws: on connect send the status snapshot, then stream
// events + relay media to the app.
func (s *Server) ws(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade: %v", err)
		return
	}
	defer conn.Close()

	// Initial status snapshot (matches web.rs handle_ws).
	init := map[string]any{
		"type":   "status",
		"linked": s.state.IsLinked(),
		"phone":  s.state.Phone(),
		"qr":     s.state.QR(),
	}
	if err := conn.WriteJSON(init); err != nil {
		return
	}

	// Subscribe to the event bus.
	sub := s.state.Bus.Subscribe()
	defer s.state.Bus.Unsubscribe(sub)

	// Media relay goroutine: forward peer audio/video to the app.
	done := make(chan struct{})
	defer close(done)
	go s.relayMediaOut(conn, done)

	// Main loop: events → text frames; app binary frames → media sources.
	for {
		select {
		case ev, ok := <-sub:
			if !ok {
				return
			}
			if err := conn.WriteMessage(websocket.TextMessage, ev.Marshal()); err != nil {
				return
			}
		default:
		}
		// Read next message (blocking) — events are drained in a separate
		// tick below.
		_, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		// Text frames are ignored by the Rust server; binary frames are media.
		if len(data) == 0 {
			continue
		}
		tag := data[0]
		payload := data[1:]
		if len(payload) == 0 {
			continue
		}
		calls := s.state.Calls.List()
		if len(calls) == 0 {
			continue
		}
		relay := s.state.Calls.Get(calls[0].CallID)
		if relay == nil {
			continue
		}
		switch tag {
		case FrameTagAudio: // mic PCM s16le → meowcaller audio source
			select {
			case relay.micCh <- payload:
			default:
			}
		case FrameTagVideo: // camera H.264 AU → meowcaller video source
			select {
			case relay.camCh <- payload:
			default:
			}
		}
	}
}

// relayMediaOut forwards peer audio/video from the call relay to the app
// (mirrors web.rs::relay_media_out):
//   audio: [1][pcm s16le bytes]
//   video: [2][keyframe:u8][h264 annex-b AU]
func (s *Server) relayMediaOut(conn *websocket.Conn, done chan struct{}) {
	for {
		select {
		case <-done:
			return
		default:
		}
		calls := s.state.Calls.List()
		if len(calls) == 0 {
			select {
			case <-done:
				return
			default:
			}
			continue
		}
		relay := s.state.Calls.Get(calls[0].CallID)
		if relay == nil {
			continue
		}
		// Peer audio → app (tag 1).
		select {
		case pcm := <-relay.peerAudioCh:
			out := make([]byte, 1+len(pcm))
			out[0] = FrameTagAudio
			copy(out[1:], pcm)
			if err := conn.WriteMessage(websocket.BinaryMessage, out); err != nil {
				return
			}
		default:
		}
		// Peer video → app (tag 2, keyframe byte).
		select {
		case frame := <-relay.peerVideoCh:
			out := make([]byte, 2+len(frame.Data))
			out[0] = FrameTagVideo
			if frame.Keyframe {
				out[1] = 1
			}
			copy(out[2:], frame.Data)
			if err := conn.WriteMessage(websocket.BinaryMessage, out); err != nil {
				return
			}
		default:
		}
	}
}

// pcmToS16le converts 16-bit little-endian PCM bytes to an int16 slice.
func pcmToS16le(b []byte) []int16 {
	n := len(b) / 2
	out := make([]int16, n)
	for i := 0; i < n; i++ {
		out[i] = int16(binary.LittleEndian.Uint16(b[i*2:]))
	}
	return out
}

// s16leToPCM converts an int16 slice to little-endian PCM bytes.
func s16leToPCM(s []int16) []byte {
	out := make([]byte, len(s)*2)
	for i, v := range s {
		binary.LittleEndian.PutUint16(out[i*2:], uint16(v))
	}
	return out
}
