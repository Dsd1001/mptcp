package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev"

type settings struct {
	mode, listen, target, serverFile                     string
	dialTimeout, userTimeout, idle                       time.Duration
	keepIdle, keepInterval                               time.Duration
	keepCount, maxConnections                            int
	softAge, softGrace, hardAge, retiredIdle, retiredAge time.Duration
	jitter                                               float64
}

func parse(args []string, output io.Writer) (settings, error) {
	c := settings{}
	if len(args) < 2 || (args[0] != "client" && args[0] != "server") || args[1] != "tcp" {
		return c, errors.New("usage: mptcp-port-tunnel client tcp|server tcp [flags], probe [flags], version")
	}
	c.mode = args[0]
	f := flag.NewFlagSet(c.mode+" tcp", flag.ContinueOnError)
	f.SetOutput(output)
	f.StringVar(&c.listen, "listen", "", "local IPv4:port listener")
	if c.mode == "client" {
		f.StringVar(&c.target, "server", "", "MPTCP destination IPv4:port")
		f.StringVar(&c.serverFile, "server-file", "", "file containing one MPTCP destination IPv4:port")
	} else {
		f.StringVar(&c.target, "target", "", "ordinary TCP backend IPv4:port")
	}
	f.DurationVar(&c.dialTimeout, "dial-timeout", 10*time.Second, "outbound connection timeout")
	f.IntVar(&c.maxConnections, "max-connections", 256, "maximum simultaneous connections")
	f.DurationVar(&c.userTimeout, "tcp-user-timeout", 45*time.Second, "Linux TCP unacknowledged-data timeout; zero disables")
	f.DurationVar(&c.keepIdle, "tcp-keepalive-idle", 2*time.Minute, "TCP keepalive idle interval")
	f.DurationVar(&c.keepInterval, "tcp-keepalive-interval", 15*time.Second, "TCP keepalive probe interval")
	f.IntVar(&c.keepCount, "tcp-keepalive-count", 3, "TCP keepalive probe count")
	f.DurationVar(&c.idle, "tcp-idle-timeout", 15*time.Minute, "bidirectional idle timeout; zero disables")
	f.DurationVar(&c.softAge, "tcp-soft-max-age", time.Hour, "retire older connections once idle; zero disables")
	f.DurationVar(&c.softGrace, "tcp-soft-age-idle-grace", 30*time.Second, "idle grace for soft age retirement")
	f.DurationVar(&c.hardAge, "tcp-hard-max-age", 2*time.Hour, "maximum connection lifetime; zero disables")
	jitter := f.String("tcp-max-age-jitter", "20%", "symmetric jitter for soft/hard maximum age, 0%-50%")
	f.DurationVar(&c.retiredIdle, "retired-target-idle-timeout", 2*time.Minute, "idle timeout after the server-file target changes")
	f.DurationVar(&c.retiredAge, "retired-target-max-age", 15*time.Minute, "maximum lifetime after the target changes")
	if err := f.Parse(args[2:]); err != nil {
		return c, err
	}
	if f.NArg() != 0 {
		return c, errors.New("unexpected positional arguments")
	}
	if err := validAddress(c.listen); err != nil {
		return c, fmt.Errorf("listen: %w", err)
	}
	if (c.target == "") == (c.serverFile == "") {
		return c, errors.New("specify exactly one destination: --server, --server-file, or server --target")
	}
	if c.target != "" {
		if err := validAddress(c.target); err != nil {
			return c, err
		}
	}
	if c.maxConnections < 1 || c.maxConnections > 65536 || c.dialTimeout <= 0 || c.keepCount < 1 || c.keepCount > 127 || c.keepIdle <= 0 || c.keepInterval <= 0 {
		return c, errors.New("invalid connection limit, dial timeout, or keepalive configuration")
	}
	for _, d := range []time.Duration{c.userTimeout, c.idle, c.softAge, c.softGrace, c.hardAge, c.retiredIdle, c.retiredAge} {
		if d < 0 || d > 365*24*time.Hour {
			return c, errors.New("timeouts must be between zero and one year")
		}
	}
	if c.userTimeout/time.Millisecond > 2147483647 {
		return c, errors.New("TCP user timeout is too large")
	}
	if c.softAge > 0 && c.hardAge > 0 && c.softAge > c.hardAge {
		return c, errors.New("soft max age exceeds hard max age")
	}
	if !strings.HasSuffix(*jitter, "%") {
		return c, errors.New("age jitter must end with %")
	}
	pct, err := strconv.ParseFloat(strings.TrimSuffix(*jitter, "%"), 64)
	if err != nil || !(pct >= 0 && pct <= 50) {
		return c, errors.New("age jitter must be 0%-50%")
	}
	c.jitter = pct / 100
	return c, nil
}

func validAddress(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	p, err := strconv.Atoi(port)
	if ip == nil || ip.To4() == nil || err != nil || p < 1 || p > 65535 {
		return fmt.Errorf("expected IPv4:port, got %q", address)
	}
	return nil
}

func readTarget(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 1025))
	if err != nil {
		return "", err
	}
	if len(data) > 1024 {
		return "", errors.New("server file exceeds 1024 bytes")
	}
	target := strings.TrimSpace(string(data))
	if err := validAddress(target); err != nil {
		return "", err
	}
	return target, nil
}

func requireMPTCP(conn *net.TCPConn) error {
	ok, err := conn.MultipathTCP()
	if err != nil {
		return fmt.Errorf("check MPTCP negotiation: %w", err)
	}
	if !ok {
		return errors.New("peer did not negotiate MPTCP; refusing TCP fallback")
	}
	return nil
}

func dial(ctx context.Context, address string, timeout time.Duration, multipath bool) (*net.TCPConn, error) {
	d := net.Dialer{Timeout: timeout}
	d.SetMultipathTCP(multipath)
	conn, err := d.DialContext(ctx, "tcp4", address)
	if err != nil {
		return nil, err
	}
	tcp := conn.(*net.TCPConn)
	if multipath {
		if err := requireMPTCP(tcp); err != nil {
			tcp.Close()
			return nil, err
		}
	}
	return tcp, nil
}

func configure(conn *net.TCPConn, c settings) error {
	if err := conn.SetKeepAliveConfig(net.KeepAliveConfig{Enable: true, Idle: c.keepIdle, Interval: c.keepInterval, Count: c.keepCount}); err != nil {
		return err
	}
	return setUserTimeout(conn, c.userTimeout)
}

type targetState struct {
	address string
	err     error
}

func serve(ctx context.Context, c settings) error {
	if runtime.GOOS != "linux" {
		return errors.New("MPTCP tunnel requires Linux")
	}
	var target atomic.Pointer[targetState]
	refresh := func() {
		state := &targetState{address: c.target}
		if c.serverFile != "" {
			state.address, state.err = readTarget(c.serverFile)
		}
		target.Store(state)
	}
	refresh()
	if state := target.Load(); state.err != nil {
		return state.err
	}
	lc := net.ListenConfig{}
	lc.SetMultipathTCP(c.mode == "server")
	listener, err := lc.Listen(ctx, "tcp4", c.listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { <-runCtx.Done(); listener.Close() }()
	if c.serverFile != "" {
		go func() {
			ticker := time.NewTicker(250 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-runCtx.Done():
					return
				case <-ticker.C:
					refresh()
				}
			}
		}()
	}
	var workers sync.WaitGroup
	defer workers.Wait()
	slots := make(chan struct{}, c.maxConnections)
	log.Printf("version=%s mode=%s listen=%s native_mptcp=%t", version, c.mode, c.listen, c.mode == "server")
	for {
		conn, err := listener.Accept()
		if err != nil {
			cancel()
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		select {
		case slots <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		workers.Add(1)
		go func(local *net.TCPConn) {
			defer workers.Done()
			defer func() { <-slots }()
			defer local.Close()
			if c.mode == "server" {
				if err := requireMPTCP(local); err != nil {
					log.Print(err)
					return
				}
			}
			state := target.Load()
			if state.err != nil {
				log.Printf("invalid target file: %v", state.err)
				return
			}
			remote, err := dial(runCtx, state.address, c.dialTimeout, c.mode == "client")
			if err != nil {
				log.Printf("dial %s: %v", state.address, err)
				return
			}
			defer remote.Close()
			for _, tcp := range []*net.TCPConn{local, remote} {
				if err := configure(tcp, c); err != nil {
					log.Printf("socket configuration: %v", err)
					return
				}
			}
			log.Printf("connected peer=%s target=%s mptcp=true", local.RemoteAddr(), state.address)
			bridge(runCtx, local, remote, c, func() bool { latest := target.Load(); return latest.err == nil && latest.address != state.address })
		}(conn.(*net.TCPConn))
	}
}

func jittered(d time.Duration, jitter float64) time.Duration {
	return time.Duration(float64(d) * (1 + jitter*(2*rand.Float64()-1)))
}

func bridge(ctx context.Context, a, b *net.TCPConn, c settings, retired func() bool) {
	defer a.Close()
	defer b.Close()
	start := time.Now()
	var last atomic.Int64
	var sent, received atomic.Int64
	last.Store(start.UnixNano())
	soft, hard := jittered(c.softAge, c.jitter), jittered(c.hardAge, c.jitter)
	done := make(chan error, 2)
	pump := func(dst, src *net.TCPConn, count *atomic.Int64) {
		buffer := make([]byte, 32*1024)
		for {
			n, err := src.Read(buffer)
			if n > 0 {
				last.Store(time.Now().UnixNano())
				data := buffer[:n]
				for len(data) > 0 {
					if c.userTimeout > 0 {
						dst.SetWriteDeadline(time.Now().Add(c.userTimeout))
					}
					written, werr := dst.Write(data)
					if written > 0 {
						count.Add(int64(written))
						last.Store(time.Now().UnixNano())
						data = data[written:]
					}
					if werr != nil {
						done <- werr
						return
					}
					if written == 0 {
						done <- io.ErrShortWrite
						return
					}
				}
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					dst.CloseWrite()
					done <- nil
				} else {
					done <- err
				}
				return
			}
		}
	}
	go pump(b, a, &sent)
	go pump(a, b, &received)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	var retiredAt time.Time
	completed := 0
	closed := false
	cancelled := ctx.Done()
	closeBoth := func() {
		if !closed {
			closed = true
			a.Close()
			b.Close()
		}
	}
	for completed < 2 {
		select {
		case err := <-done:
			completed++
			if err != nil {
				closeBoth()
			}
		case <-cancelled:
			closeBoth()
			cancelled = nil
		case now := <-ticker.C:
			idle := now.Sub(time.Unix(0, last.Load()))
			age := now.Sub(start)
			if retiredAt.IsZero() && retired() {
				retiredAt = now
			}
			if (c.idle > 0 && idle >= c.idle) || (hard > 0 && age >= hard) || (soft > 0 && age >= soft && idle >= c.softGrace) ||
				(!retiredAt.IsZero() && ((c.retiredIdle > 0 && idle >= c.retiredIdle) || (c.retiredAge > 0 && now.Sub(retiredAt) >= c.retiredAge))) {
				closeBoth()
			}
		}
	}
	log.Printf("closed sent=%d received=%d elapsed=%s", sent.Load(), received.Load(), time.Since(start).Round(time.Millisecond))
}

func probe(ctx context.Context, args []string, output io.Writer) error {
	f := flag.NewFlagSet("probe", flag.ContinueOnError)
	f.SetOutput(output)
	server := f.String("server", "", "destination IPv4:port")
	timeout := f.Duration("timeout", 3*time.Second, "MPTCP handshake timeout")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || *timeout <= 0 {
		return errors.New("invalid probe arguments")
	}
	if err := validAddress(*server); err != nil {
		return err
	}
	if runtime.GOOS != "linux" {
		return errors.New("MPTCP probe requires Linux")
	}
	conn, err := dial(ctx, *server, *timeout, true)
	if err != nil {
		return err
	}
	conn.Close()
	fmt.Fprintf(output, "mptcp=true server=%s\n", *server)
	return nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	args := os.Args[1:]
	var err error
	if len(args) == 1 && (args[0] == "version" || args[0] == "--version") {
		fmt.Printf("mptcp-ab-tunnel %s %s/%s\n", version, runtime.GOOS, runtime.GOARCH)
		return
	}
	if len(args) == 1 && (args[0] == "--help" || args[0] == "help") {
		fmt.Println("mptcp-port-tunnel client tcp|server tcp [flags], probe [flags], version")
		return
	}
	if len(args) > 0 && args[0] == "probe" {
		err = probe(ctx, args[1:], os.Stdout)
	} else {
		var c settings
		c, err = parse(args, os.Stderr)
		if err == nil {
			err = serve(ctx, c)
		}
	}
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
