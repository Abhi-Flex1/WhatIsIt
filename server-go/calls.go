package server

import (
	"context"
	"errors"
	"io"
	"log"
	"sync"

	"github.com/purpshell/meowcaller"
	"go.mau.fi/whatsmeow"
)

// FrameSamples is meowcaller's audio frame size (960 = 60ms at 16kHz).
const frameSamples = 960

// CallRegistry tracks active calls + their media relays (the app's binary
// frames bridge to meowcaller's audio/video source/sink).
type CallRegistry struct {
	mu       sync.Mutex
	state    *AppState
	relays   map[string]*CallRelay
	incoming map[string]*pendingIncoming
	mc       *meowcaller.Client
	// Wait for the meowcaller client to be installed (Phase 2 wiring).
	installOnce sync.Once
	installErr  error
}

type pendingIncoming struct {
	call *meowcaller.Call
}

// SetState attaches the app state (for the event bus).
func (r *CallRegistry) SetState(state *AppState) {
	r.mu.Lock()
	r.state = state
	r.mu.Unlock()
}

// CallRelay is the media bridge for one active call.
type CallRelay struct {
	ID    string
	Peer  string
	Video bool

	// App -> WhatsApp media (channels the WS handler feeds).
	micCh chan []byte
	camCh chan []byte

	// WhatsApp -> app media (the relay task drains).
	peerAudioCh chan []byte
	peerVideoCh chan videoFrameOut

	call      *meowcaller.Call
	muted     bool
	cameraOn  bool
	ctx       context.Context
	cancel    context.CancelFunc
	waitGroup sync.WaitGroup
}

type videoFrameOut struct {
	Keyframe bool
	Data     []byte
}

// NewCallRegistry creates an empty registry.
func NewCallRegistry() *CallRegistry {
	return &CallRegistry{
		relays:   make(map[string]*CallRelay),
		incoming: make(map[string]*pendingIncoming),
	}
}

// NewMeowcallerClient wraps a whatsmeow client with the meowcaller call engine.
// Must be constructed before the whatsmeow client connects (the engine installs
// its <ack>/<call> interception at construction).
func NewMeowcallerClient(wa *whatsmeow.Client) *meowcaller.Client {
	return meowcaller.NewClient(wa)
}

// SetMeowcaller attaches the meowcaller client (installed once, before connect).
func (r *CallRegistry) SetMeowcaller(mc *meowcaller.Client) {
	r.mu.Lock()
	r.mc = mc
	r.mu.Unlock()
}

// Get returns the relay for a call id.
func (r *CallRegistry) Get(id string) *CallRelay {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.relays[id]
}

// List returns active calls as CallSummary (id, peer, video), insertion order.
func (r *CallRegistry) List() []CallSummary {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]CallSummary, 0, len(r.relays))
	for _, c := range r.relays {
		out = append(out, CallSummary{CallID: c.ID, Peer: c.Peer, Video: c.Video})
	}
	return out
}

// CallSummary is the JSON shape for GET /call/state.
type CallSummary struct {
	CallID string `json:"callId"`
	Peer   string `json:"peer"`
	Video  bool   `json:"video"`
}

// ---- call lifecycle (from web.go handlers) ----

// StartOutgoing places a WhatsApp call via meowcaller and registers the relay.
func (r *CallRegistry) StartOutgoing(ctx context.Context, wa *WAClient, chat string, video bool) (string, error) {
	r.mu.Lock()
	mc := r.mc
	r.mu.Unlock()
	if mc == nil {
		return "", errors.New("call engine not initialized")
	}
	opts := meowcaller.CallOptions{Video: video}
	call, err := mc.CallWithOptions(ctx, chat, opts)
	if err != nil {
		return "", err
	}
	relay := newRelay(call.ID(), call.Peer().String(), video, call)
	r.attachMedia(relay)
	r.mu.Lock()
	r.relays[call.ID()] = relay
	r.mu.Unlock()
	r.state.Bus.Publish(EvCallState(call.ID(), "calling"))
	return call.ID(), nil
}

// AcceptIncoming answers a stored incoming call.
func (r *CallRegistry) AcceptIncoming(ctx context.Context, wa *WAClient, callID string, video bool) (string, error) {
	r.mu.Lock()
	p := r.incoming[callID]
	delete(r.incoming, callID)
	r.mu.Unlock()
	if p == nil {
		return "", errors.New("no such incoming call")
	}
	call := p.call
	if err := call.Answer(); err != nil {
		return "", err
	}
	relay := newRelay(call.ID(), call.Peer().String(), video, call)
	r.attachMedia(relay)
	r.mu.Lock()
	r.relays[call.ID()] = relay
	r.mu.Unlock()
	r.state.Bus.Publish(EvCallState(call.ID(), "connecting"))
	return call.ID(), nil
}

// RejectIncoming declines a stored incoming call.
func (r *CallRegistry) RejectIncoming(ctx context.Context, wa *WAClient, callID string) error {
	r.mu.Lock()
	p := r.incoming[callID]
	delete(r.incoming, callID)
	r.mu.Unlock()
	if p == nil {
		return errors.New("no such incoming call")
	}
	return p.call.Reject()
}

// Hangup ends a call and tears down its media.
func (r *CallRegistry) Hangup(ctx context.Context, wa *WAClient, callID string) error {
	r.mu.Lock()
	relay := r.relays[callID]
	delete(r.relays, callID)
	r.mu.Unlock()
	if relay == nil {
		return errors.New("no such call")
	}
	relay.stop()
	return relay.call.Hangup()
}

// SetMuted toggles the relay's outbound audio (the call still sends silence).
func (r *CallRegistry) SetMuted(callID string, muted bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if relay := r.relays[callID]; relay != nil {
		relay.muted = muted
	}
}

// SetCamera toggles outbound video.
func (r *CallRegistry) SetCamera(callID string, on bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if relay := r.relays[callID]; relay != nil {
		relay.cameraOn = on
		if relay.call != nil {
			_ = relay.call.SetVideoEnabled(on)
		}
	}
}

// OnIncomingCall stores an inbound call (from meowcaller's OnIncomingCall).
func (r *CallRegistry) OnIncomingCall(call *meowcaller.Call) {
	r.mu.Lock()
	r.incoming[call.ID()] = &pendingIncoming{call: call}
	r.mu.Unlock()
	// Notify the app (incoming_call event).
	peer := call.Peer().String()
	r.state.Bus.Publish(EvIncomingCall(call.ID(), peer, call.IsVideo()))
}

// ---- media bridge ----

func newRelay(id, peer string, video bool, call *meowcaller.Call) *CallRelay {
	ctx, cancel := context.WithCancel(context.Background())
	return &CallRelay{
		ID:          id,
		Peer:        peer,
		Video:       video,
		micCh:       make(chan []byte, 128),
		camCh:       make(chan []byte, 32),
		peerAudioCh: make(chan []byte, 128),
		peerVideoCh: make(chan videoFrameOut, 32),
		call:        call,
		ctx:         ctx,
		cancel:      cancel,
	}
}

// attachMedia wires meowcaller's source/sink to the relay's channels:
//   - the app's mic PCM (48k stereo s16le) is downmixed+resampled to 16k mono
//     float32 and played into the call;
//   - the call's peer audio (16k mono float32) is upsampled to 48k stereo
//     s16le and pushed to peerAudioCh;
//   - the app's camera H.264 AUs are sent via call.SendVideo;
//   - the call's peer H.264 AUs are pushed to peerVideoCh with a keyframe flag
//     derived from the NAL units.
func (r *CallRegistry) attachMedia(relay *CallRelay) {
	call := relay.call

	// Outbound audio: mic channel -> meowcaller AudioSource (16k mono float32).
	micSource := &pcmSource{
		in:   relay.micCh,
		done: make(chan struct{}),
	}
	relay.waitGroup.Add(1)
	go func() {
		defer relay.waitGroup.Done()
		player := call.Play(micSource)
		<-relay.ctx.Done()
		player.Stop()
	}()

	// Inbound audio: meowcaller AudioSink (16k mono float32) -> peerAudioCh
	// (48k stereo s16le).
	peerSink := &peerAudioSink{
		out:  relay.peerAudioCh,
		done: relay.ctx.Done(),
	}
	call.Receive(peerSink)

	// Video: camera channel -> call.SendVideo.
	relay.waitGroup.Add(1)
	go func() {
		defer relay.waitGroup.Done()
		for {
			select {
			case <-relay.ctx.Done():
				return
			case au := <-relay.camCh:
				if !relay.cameraOn {
					continue
				}
				if err := call.SendVideo(au); err != nil {
					log.Printf("call %s send video: %v", relay.ID, err)
				}
			}
		}
	}()

	// Inbound video: call.ReceiveVideo -> peerVideoCh (with keyframe flag).
	call.ReceiveVideo(meowcaller.VideoSinkFunc(func(au []byte) {
		select {
		case relay.peerVideoCh <- videoFrameOut{Keyframe: isKeyframe(au), Data: au}:
		case <-relay.ctx.Done():
		}
	}))

	// On end: tear down.
	call.OnEnd(func(reason string) {
		relay.stop()
		r.mu.Lock()
		delete(r.relays, relay.ID)
		r.mu.Unlock()
		r.state.Bus.Publish(EvCallState(relay.ID, "ended:"+reason))
	})
}

func (relay *CallRelay) stop() {
	if relay.cancel != nil {
		relay.cancel()
	}
	relay.waitGroup.Wait()
}

// ---- audio conversion ----

// pcmSource adapts the app's mic PCM (48k stereo s16le) to meowcaller's
// AudioSource (16k mono float32, 960-sample frames). Downmix + 1/3 resample.
type pcmSource struct {
	in    chan []byte
	done  chan struct{}
	// pending 16k mono samples not yet emitted as a full frame.
	pending []float32
}

// ReadFrame implements meowcaller.AudioSource: returns exactly 960 samples.
func (s *pcmSource) ReadFrame() ([]float32, error) {
	frame := make([]float32, frameSamples)
	n := 0
	for n < frameSamples {
		// Drain pending first.
		if len(s.pending) > 0 {
			c := copy(frame[n:], s.pending)
			s.pending = s.pending[c:]
			n += c
			continue
		}
		select {
		case <-s.done:
			if n == 0 {
				return nil, io.EOF
			}
			// Zero-pad the last partial frame.
			for i := n; i < frameSamples; i++ {
				frame[i] = 0
			}
			return frame, nil
		case pcm := <-s.in:
			samples := downmix48kStereo(pcm)
			s.pending = append(s.pending, samples...)
		}
	}
	return frame, nil
}

// Close implements meowcaller.AudioSource.
func (s *pcmSource) Close() error { return nil }

// peerAudioSink adapts meowcaller's AudioSink (16k mono float32) to the app's
// 48k stereo s16le PCM channel.
type peerAudioSink struct {
	out  chan []byte
	done <-chan struct{}
	// upsampler state
	pos float64
}

// WriteFrame implements meowcaller.AudioSink.
func (s *peerAudioSink) WriteFrame(frame []float32) error {
	pcm := upsample16kTo48kStereo(frame, &s.pos)
	select {
	case s.out <- pcm:
		return nil
	case <-s.done:
		return errSinkClosed
	}
}

// Close implements meowcaller.AudioSink.
func (s *peerAudioSink) Close() error { return nil }

// downmix48kStereo converts 48k stereo s16le to 16k mono float32 (1/3 rate,
// stereo averaged).
func downmix48kStereo(b []byte) []float32 {
	n := len(b) / 4 // stereo s16 frames
	out := make([]float32, 0, n/3+1)
	for i := 0; i < n; i += 3 {
		l := float32(int16(b[i*4])|int16(b[i*4+1])<<8) / 32768.0
		r := float32(int16(b[i*4+2])|int16(b[i*4+3])<<8) / 32768.0
		out = append(out, (l+r)/2)
	}
	return out
}

// upsample16kTo48kStereo converts 16k mono float32 to 48k stereo s16le.
func upsample16kTo48kStereo(frame []float32, pos *float64) []byte {
	out := make([]byte, 0, len(frame)*2*3*2) // 3x upsampling, 2 ch, 2 bytes
	n := len(frame)
	for i := 0; i < n; i++ {
		// 3 output samples per input (linear interp).
		cur := frame[i]
		next := cur
		if i+1 < n {
			next = frame[i+1]
		}
		for k := 0; k < 3; k++ {
			frac := float32(k) / 3.0
			v := cur*(1-frac) + next*frac
			// Clamp + convert to s16le (stereo: duplicate).
			iv := int32(v * 32768.0)
			if iv > 32767 {
				iv = 32767
			}
			if iv < -32768 {
				iv = -32768
			}
			s := uint16(int16(iv))
			out = append(out, byte(s), byte(s>>8), byte(s), byte(s>>8))
		}
	}
	*pos = 0
	return out
}

// isKeyframe reports whether an H.264 Annex-B AU begins with a keyframe NAL
// (SPS/PPS/IDR — the app's video framing needs the keyframe byte).
func isKeyframe(au []byte) bool {
	// Scan start codes (00 00 01 / 00 00 00 01).
	i := 0
	n := len(au)
	for i+3 < n {
		if au[i] == 0 && au[i+1] == 0 {
			if au[i+2] == 1 {
				nalType := au[i+3] & 0x1f
				if nalType == 5 || nalType == 7 || nalType == 8 {
					return true
				}
				return false
			}
			if i+4 < n && au[i+2] == 0 && au[i+3] == 1 {
				nalType := au[i+4] & 0x1f
				if nalType == 5 || nalType == 7 || nalType == 8 {
					return true
				}
				return false
			}
		}
		i++
	}
	return false
}

var errSinkClosed = errors.New("sink closed")
