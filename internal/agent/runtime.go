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
	cfg     Config
	api     *api.Client
	sb      *singbox.Manager
	log     *log.Logger

	// reconcile state
	mu             sync.Mutex
	appliedHash    string
	rollbackCount  int
	rollbackSince  time.Time
	safeMode       bool
	safeModeUntil  time.Time
}

func New(cfg Config) *Agent {
	logger := log.New(os.Stderr, "[vpnd] ", log.LstdFlags)
	return &Agent{
		cfg: cfg,
		api: api.NewClient(cfg.BaseURL, cfg.Token),
		sb:  singbox.NewManager(),
		log: logger,
	}
}

// Run starts all loops and blocks until SIGINT/SIGTERM.
func (a *Agent) Run() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	// Channel for config updates signalled by heartbeat.
	configCh := make(chan string, 1)

	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		a.heartbeatLoop(ctx, configCh)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		a.reconcileLoop(ctx, configCh)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		a.healthLoop(ctx)
	}()

	a.log.Printf("started: device=%s mac=%s", a.cfg.DeviceID, a.cfg.MAC)

	<-sig
	a.log.Println("shutting down")
	cancel()
	wg.Wait()
}

// localIP returns the first non-loopback IPv4 address on known interfaces.
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
