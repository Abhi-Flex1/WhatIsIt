package server

import (
	"sync"
)

// PasskeyAnswer mirrors state.rs::PasskeyAnswer.
type PasskeyAnswer struct {
	// Assertion is set when the app returned a WebAuthn assertion.
	Assertion *PasskeyAssertion
	// Cancelled is set when the user cancelled.
	Cancelled bool
}

// PasskeyAssertion carries the decoded WebAuthn assertion from the app.
type PasskeyAssertion struct {
	CredentialID []byte
	AssertionJSON []byte
}

// AppState mirrors state.rs::AppState.
type AppState struct {
	Cfg   *Config
	Store *HistoryStore
	Bus   *EventBus

	// Current QR string (while pairing).
	qrMu   sync.Mutex
	qr     string
	// Linked phone number.
	phoneMu sync.Mutex
	phone   string
	// 8-char pair code issued by /pair-code.
	pairCodeMu sync.Mutex
	pairCode   string
	// Last passkey request options JSON (recoverable via /passkey/request).
	passkeyPendingMu sync.Mutex
	passkeyPending   string
	// Pending passkey ceremony answer (the app resolves it via
	// /passkey/assertion or /passkey/cancel).
	passkeyAnswerMu sync.Mutex
	passkeyAnswer   chan PasskeyAnswer
	// Call registry (populated by calls.go).
	Calls *CallRegistry
	// Media cache (downloads incoming media; serves /media/{id}/{kind}).
	Media *mediaCache
	// Avatar cache (serves /avatar?chat=...).
	Avatars *avatarCache
	// Followed-channel metadata cache (serves /channels).
	ChannelCache *channelCache
}

// NewAppState builds the shared state.
func NewAppState(cfg *Config) (*AppState, error) {
	store, err := NewHistoryStore(cfg)
	if err != nil {
		return nil, err
	}
	return &AppState{
		Cfg:          cfg,
		Store:        store,
		Bus:          NewEventBus(),
		Calls:        NewCallRegistry(),
		Media:        newMediaCache(cfg.MediaDir),
		Avatars:      newAvatarCache(cfg.DBPath),
		ChannelCache: &channelCache{},
	}, nil
}

// IsLinked reports whether a phone number is set.
func (s *AppState) IsLinked() bool {
	s.phoneMu.Lock()
	defer s.phoneMu.Unlock()
	return s.phone != ""
}

// Phone returns the linked phone number.
func (s *AppState) Phone() string {
	s.phoneMu.Lock()
	defer s.phoneMu.Unlock()
	return s.phone
}

// SetPhone records the linked phone number.
func (s *AppState) SetPhone(phone string) {
	s.phoneMu.Lock()
	s.phone = phone
	s.phoneMu.Unlock()
	s.Store.SetPhone(phone)
}

// QR returns the current QR string.
func (s *AppState) QR() string {
	s.qrMu.Lock()
	defer s.qrMu.Unlock()
	return s.qr
}

// SetQR updates the current QR string.
func (s *AppState) SetQR(qr string) {
	s.qrMu.Lock()
	s.qr = qr
	s.qrMu.Unlock()
}

// PairCode returns the last-issued pair code.
func (s *AppState) PairCode() string {
	s.pairCodeMu.Lock()
	defer s.pairCodeMu.Unlock()
	return s.pairCode
}

// SetPairCode records the last-issued pair code.
func (s *AppState) SetPairCode(code string) {
	s.pairCodeMu.Lock()
	s.pairCode = code
	s.pairCodeMu.Unlock()
}

// PasskeyPending returns and clears the pending request options.
func (s *AppState) TakePasskeyPending() (string, bool) {
	s.passkeyPendingMu.Lock()
	defer s.passkeyPendingMu.Unlock()
	if s.passkeyPending == "" {
		return "", false
	}
	opts := s.passkeyPending
	s.passkeyPending = ""
	return opts, true
}

// SetPasskeyPending stores the latest request options.
func (s *AppState) SetPasskeyPending(options string) {
	s.passkeyPendingMu.Lock()
	s.passkeyPending = options
	s.passkeyPendingMu.Unlock()
}

// InstallPasskeyAnswer replaces (cancelling prior) the pending ceremony answer
// channel. Returns the channel the app's /passkey/assertion or /passkey/cancel
// resolves.
func (s *AppState) InstallPasskeyAnswer() chan PasskeyAnswer {
	s.passkeyAnswerMu.Lock()
	defer s.passkeyAnswerMu.Unlock()
	if old := s.passkeyAnswer; old != nil {
		select {
		case old <- PasskeyAnswer{Cancelled: true}:
		default:
		}
	}
	ch := make(chan PasskeyAnswer, 1)
	s.passkeyAnswer = ch
	return ch
}

// TakePasskeyAnswer removes the pending answer channel (the ceremony ended).
func (s *AppState) TakePasskeyAnswer() chan PasskeyAnswer {
	s.passkeyAnswerMu.Lock()
	defer s.passkeyAnswerMu.Unlock()
	ch := s.passkeyAnswer
	s.passkeyAnswer = nil
	return ch
}
