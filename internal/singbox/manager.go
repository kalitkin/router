package singbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
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
	apiTimeout     = 3 * time.Second
	selectorTag    = "proxy" // outbound tag used in Marzban-generated sing-box config
)

// Manager controls the sing-box process lifecycle.
// All public methods are safe for concurrent use.
type Manager struct {
	configPath string
	clashURL   string
	httpClient *http.Client
	mu         sync.Mutex // serializes Apply/Restart/Rollback
}

func NewManager() *Manager {
	return &Manager{
		configPath: configPath,
		clashURL:   clashAPIURL,
		httpClient: &http.Client{Timeout: apiTimeout},
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

	patched, err := injectClashAPI(data)
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
			return nil
		}
	}
	return fmt.Errorf("sing-box did not start within %s", restartTimeout)
}

// ── helpers ───────────────────────────────────────────────────────────────────

func injectClashAPI(data []byte) ([]byte, error) {
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}

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

	return json.MarshalIndent(cfg, "", "  ")
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
