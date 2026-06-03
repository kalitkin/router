package singbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

const (
	clashAPIURL    = "http://127.0.0.1:9090"
	configPath     = "/etc/sing-box/config.json"
	backupSuffix   = ".bak"
	restartTimeout = 15 * time.Second
	apiTimeout     = 8 * time.Second
	selectorTag    = "proxy" // outbound tag used in Marzban-generated sing-box config
)

// Manager controls the sing-box process lifecycle.
// All public methods are safe for concurrent use.
type Manager struct {
	configPath string
	clashURL   string
	httpClient *http.Client
	mu         sync.Mutex // serializes Apply/Restart/Rollback
	log        *log.Logger
}

func NewManager() *Manager {
	return &Manager{
		configPath: configPath,
		clashURL:   clashAPIURL,
		httpClient: &http.Client{Timeout: apiTimeout},
		log:        log.New(os.Stderr, "[singbox] ", log.LstdFlags),
	}
}

// HasConfig reports whether a config file exists and is non-empty.
func (m *Manager) HasConfig() bool {
	info, err := os.Stat(m.configPath)
	return err == nil && info.Size() > 0
}

// Apply writes a new config and attempts hot reload, falling back to restart.
// Thread-safe: only one Apply/Restart/Rollback runs at a time.
func (m *Manager) Apply(data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	patched, err := patchRouterConfig(data)
	if err != nil {
		return fmt.Errorf("patch config: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(m.configPath), 0755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}

	if err := writeAtomic(m.configPath, patched); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	// Level 1: hot reload via Clash API.
	if err := m.reloadLocked(patched); err == nil {
		return nil
	}

	// Level 2: service restart.
	if err := m.restartLocked(); err == nil {
		return nil
	}

	return fmt.Errorf("apply: all reload strategies exhausted")
}

// Restart restarts sing-box via init.d. Thread-safe.
func (m *Manager) Restart() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.restartLocked()
}

// Backup copies current config.json to config.json.bak atomically.
func (m *Manager) Backup() error {
	data, err := os.ReadFile(m.configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("backup read: %w", err)
	}
	return writeAtomic(m.configPath+backupSuffix, data)
}

// Rollback restores config from .bak and restarts sing-box. Thread-safe.
func (m *Manager) Rollback() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	bak := m.configPath + backupSuffix
	data, err := os.ReadFile(bak)
	if err != nil {
		return fmt.Errorf("no backup available: %w", err)
	}
	if err := writeAtomic(m.configPath, data); err != nil {
		return fmt.Errorf("rollback write: %w", err)
	}
	return m.restartLocked()
}

// SwitchServer selects an outbound in the sing-box selector via Clash API.
// No restart required — change is immediate.
func (m *Manager) SwitchServer(server string) error {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	body, _ := json.Marshal(map[string]string{"name": server})
	req, err := http.NewRequestWithContext(ctx, http.MethodPut,
		m.clashURL+"/proxies/"+selectorTag, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("clash API: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("switch server %q: HTTP %d", server, resp.StatusCode)
	}
	return nil
}

// CurrentServer returns the currently selected outbound in the selector.
// Returns ("", nil) when sing-box is not running or Clash API is unreachable.
func (m *Manager) CurrentServer() (string, error) {
	info, err := m.proxyInfo()
	if err != nil {
		return "", err
	}
	return info.Now, nil
}

// ListServers returns all outbounds available in the selector.
func (m *Manager) ListServers() ([]string, error) {
	info, err := m.proxyInfo()
	if err != nil {
		return nil, err
	}
	return info.All, nil
}

// proxyInfo queries Clash API for the selector state.
func (m *Manager) proxyInfo() (*clashProxyResp, error) {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		m.clashURL+"/proxies/"+selectorTag, nil)
	if err != nil {
		return nil, err
	}

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("clash API: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("proxy info: HTTP %d", resp.StatusCode)
	}

	var info clashProxyResp
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("decode proxy info: %w", err)
	}
	return &info, nil
}

type clashProxyResp struct {
	Now string   `json:"now"`
	All []string `json:"all"`
}

// IsRunning returns true if a sing-box process is alive.
func (m *Manager) IsRunning() bool {
	// pgrep without -x for busybox compatibility.
	return exec.Command("pgrep", "sing-box").Run() == nil
}

// IsAPIAlive returns true if the Clash API responds.
func (m *Manager) IsAPIAlive() bool {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.clashURL+"/version", nil)
	if err != nil {
		return false
	}
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode == http.StatusOK
}

// ── internal (caller must hold m.mu) ─────────────────────────────────────────

func (m *Manager) reloadLocked(configData []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPut,
		m.clashURL+"/configs?force=true", bytes.NewReader(configData))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("clash API: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("clash reload: HTTP %d", resp.StatusCode)
	}
	return nil
}

func (m *Manager) restartLocked() error {
	cmd := exec.Command("/etc/init.d/sing-box", "restart")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("sing-box restart: %w — %s", err, out)
	}

	deadline := time.Now().Add(restartTimeout)
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		if m.IsRunning() {
			if err := m.SetupRouting(); err != nil {
				m.log.Printf("routing setup after restart: %v", err)
			}
			return nil
		}
	}
	return fmt.Errorf("sing-box did not start within %s", restartTimeout)
}

// ReapplyPatch re-applies patchRouterConfig to the on-disk config.json.
// If patches changed (e.g. after a vpnd upgrade), it restarts sing-box.
// Returns true if a restart was performed (SetupRouting already called inside).
func (m *Manager) ReapplyPatch() (bool, error) {
	data, err := os.ReadFile(m.configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("read config: %w", err)
	}

	patched, err := patchRouterConfig(data)
	if err != nil {
		return false, fmt.Errorf("patch: %w", err)
	}

	if bytes.Equal(data, patched) {
		return false, nil
	}

	m.log.Println("reapply: config changed after re-patch (vpnd upgrade?), restarting")

	m.mu.Lock()
	defer m.mu.Unlock()

	if err := writeAtomic(m.configPath, patched); err != nil {
		return false, fmt.Errorf("write: %w", err)
	}
	return true, m.restartLocked()
}

// ── routing ───────────────────────────────────────────────────────────────────

// SetupRouting configures kernel ip rules and table 2022 for VPN forwarding.
// Must be called after every sing-box (re)start. Safe to call concurrently.
//
// Routing scheme:
//   - table 2022: default dev sing-tun  (all traffic → VPN)
//   - ip rule prio 100:  fwmark 0x64 → main  (sing-box outbound bypasses VPN)
//   - ip rule prio 2022: not fwmark 0x64 → table 2022  (LAN + router → VPN)
//
// When sing-box is down and table 2022 is empty, the kernel falls through to
// the main table, giving fail-open internet access via the physical WAN.
func (m *Manager) SetupRouting() error {
	const (
		tunIface    = "sing-tun"
		table       = "2022"
		prioBypass  = "100"
		prioVPN     = "2022"
		waitTimeout = 10 * time.Second
	)

	deadline := time.Now().Add(waitTimeout)
	for {
		if _, err := net.InterfaceByName(tunIface); err == nil {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s did not appear within %s", tunIface, waitTimeout)
		}
		time.Sleep(500 * time.Millisecond)
	}

	// BusyBox ip requires routing table names in /etc/iproute2/rt_tables.
	// sing-box uses netlink directly, so it can write to table 2022 without this,
	// but our ip(8) calls fail unless the table is named.
	const rtTablesPath = "/etc/iproute2/rt_tables"
	if data, err := os.ReadFile(rtTablesPath); err == nil && !bytes.Contains(data, []byte("2022")) {
		if f, err := os.OpenFile(rtTablesPath, os.O_APPEND|os.O_WRONLY, 0644); err == nil {
			fmt.Fprintf(f, "2022\tvpn\n")
			f.Close()
		}
	}

	// Flush stale routes, then add fresh default via sing-tun.
	exec.Command("ip", "route", "flush", "table", table).Run()
	if out, err := exec.Command(
		"ip", "route", "add", "default", "dev", tunIface, "table", table,
	).CombinedOutput(); err != nil {
		return fmt.Errorf("add default via %s table %s: %w — %s", tunIface, table, err, out)
	}

	// Delete stale rules at our priorities, then re-add.
	exec.Command("ip", "rule", "del", "priority", prioBypass).Run()
	exec.Command("ip", "rule", "del", "priority", prioVPN).Run()
	exec.Command("ip", "rule", "add", "fwmark", "0x64", "priority", prioBypass, "table", "main").Run()
	exec.Command("ip", "rule", "add", "not", "fwmark", "0x64", "priority", prioVPN, "table", table).Run()

	m.log.Printf("routing: table %s default via %s, rules prio %s/%s ready",
		table, tunIface, prioBypass, prioVPN)
	return nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

// patchRouterConfig applies all router-specific patches to the sing-box config:
// - Injects Clash API (external_controller)
// - Sets TUN stack to gvisor (mixed/system stack requires TPROXY nftables rules
//   that sing-box does not add under fw4/OpenWrt 24+; gvisor is full userspace TCP/IP)
// - Sets route.default_mark=100 so all sing-box outbound sockets bypass the TUN
//   routing table (prevents routing loop: VPN server IPs are in table 2022 via sing-tun)
func patchRouterConfig(data []byte) ([]byte, error) {
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}

	// Clash API
	exp, _ := cfg["experimental"].(map[string]any)
	if exp == nil {
		exp = map[string]any{}
	}
	if _, exists := exp["clash_api"]; !exists {
		exp["clash_api"] = map[string]any{
			"external_controller": "127.0.0.1:9090",
			"secret":              "",
		}
	}
	cfg["experimental"] = exp

	// TUN inbound: force gvisor stack; disable auto_route.
	// auto_route is disabled because we manage kernel routing explicitly —
	// OpenWrt's fw4 resets routing tables on interface events, making
	// sing-box's auto-created table 2022 unreliable. SetupRouting() handles it.
	if inbounds, ok := cfg["inbounds"].([]any); ok {
		for _, ib := range inbounds {
			ibMap, ok := ib.(map[string]any)
			if !ok {
				continue
			}
			if ibMap["type"] == "tun" {
				ibMap["auto_route"] = false
				if _, exists := ibMap["stack"]; !exists {
					ibMap["stack"] = "gvisor"
				}
			}
		}
	}

	// route.default_mark: 100
	route, _ := cfg["route"].(map[string]any)
	if route == nil {
		route = map[string]any{}
	}
	route["default_mark"] = 100
	cfg["route"] = route

	// interrupt_exist_connections: false on all outbounds.
	// Marzban sets this to true on selector/urltest, which drops ALL active
	// connections on the router when switching servers — kills every LAN client.
	if outbounds, ok := cfg["outbounds"].([]any); ok {
		for _, ob := range outbounds {
			obMap, ok := ob.(map[string]any)
			if !ok {
				continue
			}
			obType, _ := obMap["type"].(string)
			if obType == "selector" || obType == "urltest" {
				obMap["interrupt_exist_connections"] = false
			}
		}
	}

	return json.MarshalIndent(cfg, "", "  ")
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
