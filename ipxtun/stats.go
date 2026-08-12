package main

import (
	"fmt"
	"log"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

type Stats struct {
	Start time.Time

	TxPackets atomic.Uint64
	TxBytes   atomic.Uint64
	TxErrors  atomic.Uint64
	RxPackets atomic.Uint64
	RxBytes   atomic.Uint64
	RxErrors  atomic.Uint64

	AuthFailed  atomic.Uint64
	ReplayDrops atomic.Uint64
	TunDrops    atomic.Uint64
	PoolStalls  atomic.Uint64
	Oversize    atomic.Uint64

	PeerUp       atomic.Bool
	PeerRTTMicro atomic.Int64
	LastRxUnix   atomic.Int64
	PeerFlaps    atomic.Uint64

	TCPOpen      atomic.Uint64
	TCPActive    atomic.Int64
	TCPFailed    atomic.Uint64
	UDPActive    atomic.Int64
	UDPFailed    atomic.Uint64
	FwdBytesUp   atomic.Uint64
	FwdBytesDown atomic.Uint64
}

func NewStats() *Stats {
	return &Stats{Start: time.Now()}
}

func (s *Stats) Uptime() time.Duration { return time.Since(s.Start) }

// ---------- logging ----------

type Level int

const (
	LevelTrace Level = iota
	LevelDebug
	LevelInfo
	LevelWarn
	LevelError
)

func parseLevel(s string) Level {
	switch strings.ToLower(s) {
	case "trace":
		return LevelTrace
	case "debug":
		return LevelDebug
	case "warn", "warning":
		return LevelWarn
	case "error", "fatal", "panic":
		return LevelError
	default:
		return LevelInfo
	}
}

type Logger struct {
	lvl Level
	l   *log.Logger
	// rate limiting for the noisy paths (a hostile scanner should not be able to
	// fill the journal by spraying packets at us)
	lastNoisy  atomic.Int64
	suppressed atomic.Uint64
}

func NewLogger(level string) *Logger {
	return &Logger{
		lvl: parseLevel(level),
		l:   log.New(os.Stdout, "", log.LstdFlags|log.Lmicroseconds),
	}
}

func (g *Logger) logf(lvl Level, tag, format string, args ...any) {
	if lvl < g.lvl {
		return
	}
	g.l.Printf("["+tag+"] "+format, args...)
}

func (g *Logger) Tracef(f string, a ...any) { g.logf(LevelTrace, "trace", f, a...) }
func (g *Logger) Debugf(f string, a ...any) { g.logf(LevelDebug, "debug", f, a...) }
func (g *Logger) Infof(f string, a ...any)  { g.logf(LevelInfo, "info", f, a...) }
func (g *Logger) Warnf(f string, a ...any)  { g.logf(LevelWarn, "warn", f, a...) }
func (g *Logger) Errorf(f string, a ...any) { g.logf(LevelError, "error", f, a...) }

// Noisyf collapses repeated per-packet complaints into one line per second.
func (g *Logger) Noisyf(format string, args ...any) {
	if LevelDebug < g.lvl {
		return
	}
	now := time.Now().Unix()
	last := g.lastNoisy.Load()
	if last == now {
		g.suppressed.Add(1)
		return
	}
	if g.lastNoisy.CompareAndSwap(last, now) {
		n := g.suppressed.Swap(0)
		if n > 0 {
			format += fmt.Sprintf(" (+%d similar suppressed)", n)
		}
		g.logf(LevelDebug, "debug", format, args...)
	}
}
