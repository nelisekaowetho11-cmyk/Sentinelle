package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"sync"
)

// Wire format
//
//	 0                   1
//	 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
//	+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//	| v | t |  padLen   | sessionID |   counter (8)                 |
//	+-------------------------------+
//
// The 16-byte header is encrypted as a single AES block before it goes on the
// wire, so every byte of every packet is indistinguishable from random to an
// observer. The obfuscated header doubles as the AEAD's associated data, so it
// cannot be tampered with. The nonce is sessionID||counter, which is unique for
// the life of a process: sessionID is fresh random on every start and the
// counter never repeats (each worker owns a disjoint range).
const (
	hdrLen        = 16
	tagLen        = 16
	frameOverhead = hdrLen + tagLen
	protoVersion  = 1

	ptData = byte(0)
	ptPing = byte(1)
	ptPong = byte(2)
)

var (
	errShortFrame = errors.New("frame shorter than header+tag")
	errBadVersion = errors.New("header version mismatch")
	errAuth       = errors.New("authentication failed")
)

// Crypto holds the immutable keys shared by every worker.
type Crypto struct {
	aead     cipher.AEAD
	hdrEnc   cipher.Block // header obfuscation, encrypt direction
	hdrDec   cipher.Block // same key, decrypt direction
	enabled  bool
	icmpID   uint16
	sessions sync.Map // uint32 sessionID -> *replayWindow
}

func deriveKey(psk string, iterations int, label string, n int) []byte {
	// A PSK is meant to be high-entropy base64; if it decodes cleanly we use the
	// raw bytes, otherwise we take the string as-is so a human-typed passphrase
	// still works.
	var seed []byte
	if b, err := base64.StdEncoding.DecodeString(psk); err == nil && len(b) >= 16 {
		seed = b
	} else {
		seed = []byte(psk)
	}
	return pbkdf2SHA256(seed, []byte("ipxtun/v1/"+label), iterations, n)
}

func NewCrypto(cfg *Config) (*Crypto, error) {
	c := &Crypto{enabled: cfg.EnableEncryption}
	if !c.enabled {
		return c, nil
	}

	keyLen := 32
	if cfg.Algorithm == "aes-128-gcm" {
		keyLen = 16
	}

	dataKey := deriveKey(cfg.PSK, cfg.KDFIterations, "data", keyLen)
	hdrKey := deriveKey(cfg.PSK, cfg.KDFIterations, "header", 16)
	idKey := deriveKey(cfg.PSK, cfg.KDFIterations, "icmp-id", 2)

	blk, err := aes.NewCipher(dataKey)
	if err != nil {
		return nil, fmt.Errorf("aes: %v", err)
	}
	c.aead, err = cipher.NewGCM(blk)
	if err != nil {
		return nil, fmt.Errorf("gcm: %v", err)
	}
	if c.hdrEnc, err = aes.NewCipher(hdrKey); err != nil {
		return nil, fmt.Errorf("header cipher: %v", err)
	}
	c.hdrDec = c.hdrEnc
	c.icmpID = binary.BigEndian.Uint16(idKey)
	if c.icmpID == 0 {
		c.icmpID = 1
	}
	return c, nil
}

// replay returns the sliding window for a peer session, creating it on first
// sight. A peer restart produces a new sessionID and therefore a clean window.
func (c *Crypto) replay(session uint32) *replayWindow {
	if w, ok := c.sessions.Load(session); ok {
		return w.(*replayWindow)
	}
	w := newReplayWindow()
	actual, _ := c.sessions.LoadOrStore(session, w)
	return actual.(*replayWindow)
}

// codec is the per-worker, allocation-free encoder/decoder.
type codec struct {
	c       *Crypto
	session uint32
	counter uint64
	maxPad  int

	hdr   [hdrLen]byte
	obf   [hdrLen]byte
	nonce [12]byte
	buf   []byte // scratch for plaintext+padding
	rng   uint64 // xorshift state for pad lengths
}

func newCodec(c *Crypto, session uint32, worker int, maxPad, mtu int) *codec {
	var s [8]byte
	_, _ = rand.Read(s[:])
	seed := binary.BigEndian.Uint64(s[:])
	if seed == 0 {
		seed = 0x9E3779B97F4A7C15
	}
	return &codec{
		c:       c,
		session: session,
		// Each worker owns the top byte of the counter space, so two workers can
		// never produce the same nonce without any cross-worker synchronisation.
		counter: uint64(worker) << 56,
		maxPad:  maxPad,
		buf:     make([]byte, mtu+512),
		rng:     seed,
	}
}

func (d *codec) next() uint64 {
	d.counter++
	return d.counter
}

func (d *codec) rand() uint64 {
	d.rng ^= d.rng << 13
	d.rng ^= d.rng >> 7
	d.rng ^= d.rng << 17
	return d.rng
}

// Seal writes an encrypted frame for payload into out (which must have room for
// len(payload)+frameOverhead+maxPad) and returns the filled prefix.
func (d *codec) Seal(out []byte, typ byte, payload []byte) ([]byte, error) {
	pad := 0
	if d.maxPad > 0 && typ == ptData {
		pad = int(d.rand() % uint64(d.maxPad+1))
	}

	ctr := d.next()
	d.hdr[0] = protoVersion
	d.hdr[1] = typ
	binary.BigEndian.PutUint16(d.hdr[2:4], uint16(pad))
	binary.BigEndian.PutUint32(d.hdr[4:8], d.session)
	binary.BigEndian.PutUint64(d.hdr[8:16], ctr)

	if !d.c.enabled {
		n := copy(out, d.hdr[:])
		n += copy(out[n:], payload)
		return out[:n], nil
	}

	d.c.hdrEnc.Encrypt(d.obf[:], d.hdr[:])

	copy(d.nonce[0:4], d.hdr[4:8])
	copy(d.nonce[4:12], d.hdr[8:16])

	plain := payload
	if pad > 0 {
		need := len(payload) + pad
		if cap(d.buf) < need {
			d.buf = make([]byte, need)
		}
		plain = d.buf[:need]
		copy(plain, payload)
		// Pad content is encrypted anyway, so a cheap PRNG is plenty here.
		r := d.rand()
		for i := len(payload); i < need; i++ {
			if (i-len(payload))%8 == 0 {
				r = d.rand()
			}
			plain[i] = byte(r)
			r >>= 8
		}
	}

	copy(out, d.obf[:])
	sealed := d.c.aead.Seal(out[:hdrLen], d.nonce[:], plain, d.obf[:])
	return sealed, nil
}

// Open authenticates and decrypts a frame in place-ish: the plaintext is
// written into out and returned as a subslice.
func (d *codec) Open(out, wire []byte) (typ byte, session uint32, counter uint64, plain []byte, err error) {
	if len(wire) < hdrLen+tagLen {
		if !d.c.enabled && len(wire) >= hdrLen {
			// unencrypted mode has no tag
		} else {
			return 0, 0, 0, nil, errShortFrame
		}
	}

	if !d.c.enabled {
		if wire[0] != protoVersion {
			return 0, 0, 0, nil, errBadVersion
		}
		typ = wire[1]
		session = binary.BigEndian.Uint32(wire[4:8])
		counter = binary.BigEndian.Uint64(wire[8:16])
		n := copy(out, wire[hdrLen:])
		return typ, session, counter, out[:n], nil
	}

	d.c.hdrDec.Decrypt(d.hdr[:], wire[:hdrLen])
	if d.hdr[0] != protoVersion {
		return 0, 0, 0, nil, errBadVersion
	}
	typ = d.hdr[1]
	pad := int(binary.BigEndian.Uint16(d.hdr[2:4]))
	session = binary.BigEndian.Uint32(d.hdr[4:8])
	counter = binary.BigEndian.Uint64(d.hdr[8:16])

	copy(d.nonce[0:4], d.hdr[4:8])
	copy(d.nonce[4:12], d.hdr[8:16])

	opened, e := d.c.aead.Open(out[:0], d.nonce[:], wire[hdrLen:], wire[:hdrLen])
	if e != nil {
		return 0, 0, 0, nil, errAuth
	}
	if pad > 0 {
		if pad > len(opened) {
			return 0, 0, 0, nil, errAuth
		}
		opened = opened[:len(opened)-pad]
	}
	return typ, session, counter, opened, nil
}

// replayWindow is a sharded sliding-window anti-replay filter. Shards are keyed
// by the sender's worker id (the counter's top byte), which is exactly how the
// sender partitions the space, so shards see monotonic sequences and lock
// contention stays near zero.
const (
	replayShards = 256
	windowBits   = 4096
	windowWords  = windowBits / 64
)

type replayShard struct {
	mu     sync.Mutex
	latest uint64
	bitmap [windowWords]uint64
	seen   bool
}

type replayWindow struct {
	shards [replayShards]replayShard
}

func newReplayWindow() *replayWindow { return &replayWindow{} }

// accept reports whether counter is fresh, and records it.
func (w *replayWindow) accept(counter uint64) bool {
	s := &w.shards[counter>>56]
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.seen {
		s.seen = true
		s.latest = counter
		s.set(counter)
		return true
	}

	switch {
	case counter > s.latest:
		diff := counter - s.latest
		if diff >= windowBits {
			for i := range s.bitmap {
				s.bitmap[i] = 0
			}
		} else {
			for i := uint64(1); i <= diff; i++ {
				s.clear(s.latest + i)
			}
		}
		s.latest = counter
		s.set(counter)
		return true
	case s.latest-counter >= windowBits:
		return false // too old
	default:
		if s.get(counter) {
			return false // duplicate
		}
		s.set(counter)
		return true
	}
}

func (s *replayShard) idx(c uint64) (uint64, uint64) {
	b := c % windowBits
	return b / 64, b % 64
}
func (s *replayShard) set(c uint64)      { w, b := s.idx(c); s.bitmap[w] |= 1 << b }
func (s *replayShard) clear(c uint64)    { w, b := s.idx(c); s.bitmap[w] &^= 1 << b }
func (s *replayShard) get(c uint64) bool { w, b := s.idx(c); return s.bitmap[w]&(1<<b) != 0 }

// pbkdf2SHA256 is RFC 2898 PBKDF2 with HMAC-SHA256, so we need no third-party
// crypto module.
func pbkdf2SHA256(password, salt []byte, iter, keyLen int) []byte {
	h := hmac.New(sha256.New, password)
	hashLen := h.Size()
	blocks := (keyLen + hashLen - 1) / hashLen

	out := make([]byte, 0, blocks*hashLen)
	buf := make([]byte, 4)
	u := make([]byte, hashLen)
	t := make([]byte, hashLen)

	for b := 1; b <= blocks; b++ {
		h.Reset()
		h.Write(salt)
		binary.BigEndian.PutUint32(buf, uint32(b))
		h.Write(buf)
		u = h.Sum(u[:0])
		copy(t, u)

		for i := 1; i < iter; i++ {
			h.Reset()
			h.Write(u)
			u = h.Sum(u[:0])
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

func randSession() uint32 {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("system entropy unavailable: " + err.Error())
	}
	v := binary.BigEndian.Uint32(b[:])
	if v == 0 {
		v = 1
	}
	return v
}

func generatePSK() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(b), nil
}
