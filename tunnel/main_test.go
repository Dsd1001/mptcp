package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParse(t *testing.T) {
	base := []string{"client", "tcp", "--listen", "127.0.0.1:19001", "--server", "192.0.2.1:29001"}
	if _, err := parse(base, io.Discard); err != nil {
		t.Fatal(err)
	}
	for _, extra := range [][]string{{"--server-file", "/tmp/target"}, {"--tcp-max-age-jitter", "NaN%"}, {"--tcp-max-age-jitter", "51%"}, {"--tcp-hard-max-age", "1s"}, {"--max-connections", "0"}, {"--tcp-idle-timeout", "-1s"}, {"--tcp-hard-max-age", "2000000h"}, {"--listen", "localhost:80"}} {
		if _, err := parse(append(append([]string{}, base...), extra...), io.Discard); err == nil {
			t.Errorf("accepted %v", extra)
		}
	}
	if _, err := parse([]string{"server", "tcp", "--listen", "0.0.0.0:30001", "--target", "127.0.0.1:80"}, io.Discard); err != nil {
		t.Fatal(err)
	}
}

func TestReadTarget(t *testing.T) {
	p := filepath.Join(t.TempDir(), "target")
	for _, s := range []string{"", "192.0.2.1:0", "192.0.2.1:80\n192.0.2.2:80", strings.Repeat("x", 1025)} {
		if err := os.WriteFile(p, []byte(s), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := readTarget(p); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
	os.WriteFile(p, []byte("192.0.2.1:8001\n"), 0600)
	if got, err := readTarget(p); err != nil || got != "192.0.2.1:8001" {
		t.Fatalf("%q %v", got, err)
	}
}

func tcpPair(t *testing.T) (*net.TCPConn, *net.TCPConn) {
	t.Helper()
	lc := net.ListenConfig{}
	lc.SetMultipathTCP(false)
	l, err := lc.Listen(context.Background(), "tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	a, err := dial(context.Background(), l.Addr().String(), time.Second, false)
	if err != nil {
		t.Fatal(err)
	}
	b, err := l.Accept()
	if err != nil {
		a.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close(); b.Close() })
	a.SetDeadline(time.Now().Add(3 * time.Second))
	b.(*net.TCPConn).SetDeadline(time.Now().Add(3 * time.Second))
	return a, b.(*net.TCPConn)
}

func TestBridgeHalfClose(t *testing.T) {
	user, a := tcpPair(t)
	b, backend := tcpPair(t)
	done := make(chan struct{})
	go func() { bridge(context.Background(), a, b, settings{}, func() bool { return false }); close(done) }()
	request := bytes.Repeat([]byte("request"), 10000)
	sent := make(chan error, 1)
	go func() { _, err := user.Write(request); user.CloseWrite(); sent <- err }()
	got, err := io.ReadAll(backend)
	if err != nil || !bytes.Equal(got, request) {
		t.Fatalf("request len=%d err=%v", len(got), err)
	}
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	backend.Write([]byte("response after EOF"))
	backend.CloseWrite()
	got, err = io.ReadAll(user)
	if err != nil || string(got) != "response after EOF" {
		t.Fatalf("response %q err=%v", got, err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("bridge did not finish")
	}
}

func TestBridgeLimitsAndCancel(t *testing.T) {
	for _, mode := range []string{"idle", "hard", "retired", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			_, a := tcpPair(t)
			b, _ := tcpPair(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			c := settings{}
			switch mode {
			case "idle":
				c.idle = 50 * time.Millisecond
			case "hard":
				c.hardAge = 50 * time.Millisecond
			case "retired":
				c.retiredAge = 50 * time.Millisecond
			}
			done := make(chan struct{})
			go func() { bridge(ctx, a, b, c, func() bool { return mode == "retired" }); close(done) }()
			if mode == "cancel" {
				cancel()
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("connection lifetime limit did not close bridge")
			}
		})
	}
}

func TestRejectPlainTCP(t *testing.T) {
	a, _ := tcpPair(t)
	if err := requireMPTCP(a); err == nil {
		t.Fatal("plain TCP accepted as MPTCP")
	}
}
