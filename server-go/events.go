package server

import (
	"encoding/json"
	"sync"
)

// Event mirrors state.rs::Event — the outbound WS push contract.
type Event struct {
	Type string `json:"type"`

	// qr / linked / message / receipt / incoming_call / call_state / pair_code
	Qr    string `json:"qr,omitempty"`
	Phone string `json:"phone,omitempty"`
	Chat  string `json:"chat,omitempty"`

	// incoming_call / call_state (camelCase fields)
	CallID string `json:"callId,omitempty"`
	From   string `json:"from,omitempty"`
	Video  bool   `json:"video,omitempty"`
	State  string `json:"state,omitempty"`

	// passkey_request / passkey_confirmation / passkey_error
	Options string `json:"options,omitempty"`
	Code    string `json:"code,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Constructors mirror the Rust Event variants' JSON exactly.
func EvQr(qr string) *Event          { return &Event{Type: "qr", Qr: qr} }
func EvLinked(phone string) *Event   { return &Event{Type: "linked", Phone: phone} }
func EvMessage(chat string) *Event   { return &Event{Type: "message", Chat: chat} }
func EvReceipt(chat string) *Event   { return &Event{Type: "receipt", Chat: chat} }
func EvChats() *Event                { return &Event{Type: "chats"} }
func EvLoggedOut() *Event            { return &Event{Type: "logged_out"} }
func EvPairCode(code string) *Event  { return &Event{Type: "pair_code", Code: code} }
func EvPasskeyReq(options string) *Event {
	return &Event{Type: "passkey_request", Options: options}
}
func EvPasskeyConf(code string) *Event {
	return &Event{Type: "passkey_confirmation", Code: code}
}
func EvPasskeyErr(err string) *Event { return &Event{Type: "passkey_error", Error: err} }

// EvIncomingCall mirrors Event::IncomingCall.
func EvIncomingCall(callID, from string, video bool) *Event {
	return &Event{Type: "incoming_call", CallID: callID, From: from, Video: video}
}

// EvCallState mirrors Event::CallState.
func EvCallState(callID, state string) *Event {
	return &Event{Type: "call_state", CallID: callID, State: state}
}

// Marshal renders the event as its WS text frame (type + fields).
func (e *Event) Marshal() []byte {
	b, _ := json.Marshal(e)
	return b
}

// EventBus broadcasts events to WS subscribers (broadcast-channel semantics).
type EventBus struct {
	mu   sync.Mutex
	subs map[chan *Event]struct{}
}

// NewEventBus creates an empty bus.
func NewEventBus() *EventBus {
	return &EventBus{subs: make(map[chan *Event]struct{})}
}

// Subscribe returns a new subscriber channel (buffered, like broadcast::channel).
func (b *EventBus) Subscribe() chan *Event {
	ch := make(chan *Event, 256)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

// Unsubscribe removes a subscriber.
func (b *EventBus) Unsubscribe(ch chan *Event) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
}

// Publish sends an event to all subscribers, dropping it if a buffer is full
// (non-blocking, matching tokio broadcast semantics).
func (b *EventBus) Publish(ev *Event) {
	b.mu.Lock()
	subs := make([]chan *Event, 0, len(b.subs))
	for ch := range b.subs {
		subs = append(subs, ch)
	}
	b.mu.Unlock()
	for _, ch := range subs {
		select {
		case ch <- ev:
		default:
		}
	}
}

// Binary media frame tags (match web.rs handle_ws / relay_media_out).
const (
	FrameTagAudio = 1 // mic PCM s16le -> AudioSource; peer PCM -> app speaker
	FrameTagVideo = 2 // camera H.264 AU -> VideoSource; peer AU -> app display
)
