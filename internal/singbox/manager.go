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
	"time"
)

const (
	clashAPIURL    = "http://127.0.0.1:9090"
	configPath     = "/etc/sing-box/config.json"
	backupSuffix   = ".bak"
	restartTimeout = 15 * time.Second
	apiTimeout     = 3 * time.Second
)

type Manager struct {
	configPath  string
	clashURL    string
	httpClient  *http.Client
}

func NewManager() *Manager {
	return &Manager{
		configPath: configPath,
		clashURL:   clashAPIURL,
		httpClient: &http.Client{Timeout: apiTimeout},
	}
}

// Apply writes a new config and attempts hot reload, falling back to restart.
// Returns nil if sing-box is running with the new config.
func (m *Manager) Apply(data []byte) error {
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

	// Level 1: hot reload via Clash API
	if err := m.reload(patched); err == nil {
		return nil
	}

	// Level 2: service restart
	if err := m.Restart(); err == nil {
		return nil
	}

	// Level 3: rollback
	return fmt.Errorf("apply failed: all reload strategies exhausted")
}

// Reload sends new config to Clash API without restarting the process.
func (m *Manager) reload(configData []byte) error {
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
		return fmt.Errorf("clash API unreachable: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("clash reload: HTTP %d", resp.StatusCode)
	}
	return nil
}

// Restart restarts sing-box via OpenWrt init.d and waits for it to come up.
func (m *Manager) Restart() error {
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

// Backup copies current config to config.json.bak.
func (m *Manager) Backup() error {
	src := m.configPath
	dst := m.configPath + backupSuffix
	data, err := os.ReadFile(src)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("backup read: %w", err)
	}
	return writeAtomic(dst, data)
}

// Rollback restores config from .bak and restarts sing-box.
func (m *Manager) Rollback() error {
	bak := m.configPath + backupSuffix
	data, err := os.ReadFile(bak)
	if err != nil {
		return fmt.Errorf("no backup available: %w", err)
	}
	if err := writeAtomic(m.configPath, data); err != nil {
		return fmt.Errorf("rollback write: %w", err)
	}
	return m.Restart()
}

// IsRunning returns true if sing-box process is found.
func (m *Manager) IsRunning() bool {
	err := exec.Command("pgrep", "-x", "sing-box").Run()
	return err == nil
}

// IsAPIAlive returns true if Clash API responds to /version.
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

// injectClashAPI adds the experimental.clash_api section to the config.
func injectClashAPI(data []byte) ([]byte, error) {
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}

	exp, _ := cfg["experimental"].(map[string]any)
	if exp == nil {
		exp = map[string]any{}
	}
	// Only set if not already configured by server.
	if _, exists := exp["clash_api"]; !exists {
		exp["clash_api"] = map[string]any{
			"external_controller": "127.0.0.1:9090",
			"secret":              "",
		}
	}
	cfg["experimental"] = exp

	return json.MarshalIndent(cfg, "", "  ")
}

// writeAtomic writes data to a temp file then renames into place.
func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
