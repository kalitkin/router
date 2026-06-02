package agent

import (
	"context"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/kalitkin/router/internal/api"
	"github.com/kalitkin/router/internal/singbox"
)

const (
	reconcileInterval = 5 * time.Minute
	healEvery         = 4
	maxRollbacks      = 3
	rollbackWindow    = 10 * time.Minute
	safeModeWait      = 1 * time.Hour
)

type Config struct {
	Dir      string
	Token    string
	DeviceID string
	MAC      string
	Firmware string
	BaseURL  string
}

type Agent struct {
	cfg Config
	api *api.Client
	sb  *singbox.Manager
	log *log.Logger

	// reconcile state
	mu            sync.Mutex
	appliedHash   string
	rollbackCount int
	rollbackSince time.Time
	safeMode      bool
	safeModeUntil time.Time

	// command state
	lastCmdID     string         // dedup: skip already-executed commands
	lastCmdResult *CommandResult // reported on next heartbeat

	// inter-loop signalling
	forceReconcile chan struct{}
}

func New(cfg Config) *Agent {
	return &Agent{
		cfg:            cfg,
		api:            api.NewClient(cfg.BaseURL, cfg.Token),
		sb:             singbox.NewManager(),
		log:            log.New(os.Stderr, "[vpnd] ", log.LstdFlags),
		forceReconcile: make(chan struct{}, 1),
	}
}

// Run starts all loops and blocks until SIGINT/SIGTERM.
func (a *Agent) Run() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	// configCh: heartbeat → reconcile (new sub_link)
	configCh := make(chan string, 1)
	// cmdCh: heartbeat → commandLoop (buffer 1: one command in-flight at a time,
	// matching the single Command field in HeartbeatResp)
	cmdCh := make(chan *Command, 1)

	var wg sync.WaitGroup

	for _, fn := range []func(){
		func() { a.heartbeatLoop(ctx, configCh, cmdCh) },
		func() { a.reconcileLoop(ctx, configCh) },
		func() { a.healthLoop(ctx) },
		func() { a.commandLoop(ctx, cmdCh) },
	} {
		wg.Add(1)
		go func(f func()) {
			defer wg.Done()
			f()
		}(fn)
	}

	a.log.Printf("started: device=%s mac=%s", a.cfg.DeviceID, a.cfg.MAC)

	<-sig
	a.log.Println("shutting down")
	cancel()
	wg.Wait()
}

// localIP returns the first non-loopback IPv4 on known interfaces.
func localIP() string {
	for _, name := range []string{"br-lan", "eth0", "wan"} {
		iface, err := net.InterfaceByName(name)
		if err != nil {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip4 := ip.To4(); ip4 != nil && !ip4.IsLoopback() {
				return ip4.String()
			}
		}
	}
	return ""
}
