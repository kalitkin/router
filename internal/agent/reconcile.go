package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (a *Agent) reconcileLoop(ctx context.Context, configCh <-chan string) {
	ticker := time.NewTicker(reconcileInterval)
	defer ticker.Stop()

	a.applyFromDisk()

	for {
		select {
		case <-ctx.Done():
			return

		case subLink := <-configCh:
			a.log.Println("reconcile: config update from heartbeat")
			if err := a.applySubLink(subLink); err != nil {
				a.log.Printf("reconcile: apply failed: %v", err)
			}

		case <-a.forceReconcile:
			subLink := a.readSubLink()
			if subLink == "" {
				continue
			}
			a.log.Println("reconcile: forced by command")
			if err := a.applySubLink(subLink); err != nil {
				a.log.Printf("reconcile: apply failed: %v", err)
			}

		case <-ticker.C:
			subLink := a.readSubLink()
			if subLink == "" {
				continue
			}
			a.log.Println("reconcile: periodic check")
			if err := a.applySubLink(subLink); err != nil {
				a.log.Printf("reconcile: apply failed: %v", err)
			}
		}
	}
}

func (a *Agent) applySubLink(subLink string) error {
	a.mu.Lock()
	inSafe := a.safeMode && time.Now().Before(a.safeModeUntil)
	if !inSafe && a.safeMode {
		// Safe mode window expired — reset.
		a.safeMode = false
		a.rollbackCount = 0
		a.log.Println("reconcile: safe mode lifted")
	}
	a.mu.Unlock()

	if inSafe {
		a.log.Println("reconcile: SAFE MODE — skipping")
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	data, err := a.api.GetSingBoxConfig(ctx, subLink)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}

	// Use semantic hash: ignore REALITY server_name rotation (Marzban anti-DPI).
	// sing-box restarts only when server/port/keys actually change.
	hash := semanticHash(data)

	a.mu.Lock()
	unchanged := hash == a.appliedHash
	a.mu.Unlock()

	if unchanged {
		return nil
	}

	a.log.Printf("reconcile: new config hash=%s…", hash[:12])

	// Remember which server the user selected before we touch anything.
	prevServer, _ := a.sb.CurrentServer()

	// Backup the current working config before we touch anything.
	if err := a.sb.Backup(); err != nil {
		a.log.Printf("reconcile: backup warning: %v", err)
	}

	if err := a.sb.Apply(data); err != nil {
		a.log.Printf("reconcile: apply error: %v — rolling back", err)
		return a.doRollback()
	}

	// Restore the user-selected server — Apply() resets selector to default.
	if prevServer != "" {
		if err := a.sb.SwitchServer(prevServer); err != nil {
			a.log.Printf("reconcile: restore selector %q: %v", prevServer, err)
		}
	}

	// Persist state.
	_ = writeFile(filepath.Join(a.cfg.Dir, "config"), subLink)
	_ = writeFile(filepath.Join(a.cfg.Dir, "applied_hash"), hash)

	a.mu.Lock()
	a.appliedHash = hash
	a.mu.Unlock()

	a.log.Printf("reconcile: applied config hash=%s…", hash[:12])
	return nil
}

// applyFromDisk ensures sing-box is running on daemon startup.
func (a *Agent) applyFromDisk() {
	if !a.sb.HasConfig() {
		a.log.Println("startup: no config on disk, waiting for server")
		return
	}

	if stored := a.readAppliedHash(); stored != "" {
		a.mu.Lock()
		a.appliedHash = stored
		a.mu.Unlock()
	}

	if a.sb.IsRunning() {
		a.log.Println("startup: sing-box already running")
		return
	}

	a.log.Println("startup: sing-box not running — restarting")
	if err := a.sb.Restart(); err != nil {
		a.log.Printf("startup: restart failed: %v", err)
	}
}

// doRollback increments the rollback counter and activates safe mode when
// the threshold is exceeded. Safe for concurrent use.
func (a *Agent) doRollback() error {
	a.mu.Lock()
	now := time.Now()
	// Reset counter if outside the tracking window.
	if a.rollbackSince.IsZero() || now.Sub(a.rollbackSince) > rollbackWindow {
		a.rollbackCount = 0
		a.rollbackSince = now
	}
	a.rollbackCount++
	count := a.rollbackCount
	if count > maxRollbacks {
		a.safeMode = true
		a.safeModeUntil = now.Add(safeModeWait)
	}
	a.mu.Unlock()

	a.log.Printf("rollback #%d", count)

	if count > maxRollbacks {
		a.log.Printf("SAFE MODE: %d rollbacks in %s — pausing reconcile for %s",
			count, rollbackWindow, safeModeWait)
		return fmt.Errorf("safe mode activated after %d rollbacks", count)
	}

	if err := a.sb.Rollback(); err != nil {
		return fmt.Errorf("rollback: %w", err)
	}
	a.log.Println("rollback: restored previous config")
	return nil
}

func (a *Agent) readSubLink() string {
	data, _ := os.ReadFile(filepath.Join(a.cfg.Dir, "config"))
	return strings.TrimSpace(string(data))
}

func (a *Agent) readAppliedHash() string {
	data, _ := os.ReadFile(filepath.Join(a.cfg.Dir, "applied_hash"))
	return strings.TrimSpace(string(data))
}

func sha256hex(data []byte) string {
	h := sha256.Sum256(data)
	return fmt.Sprintf("%x", h)
}

// semanticHash hashes the config after stripping volatile TLS fields.
// Marzban rotates tls.server_name on every subscription fetch for anti-DPI
// diversity — across ALL outbound types, not just Reality. We want sing-box
// to reload only when server/port/uuid actually change.
// Falls back to sha256hex on parse error.
func semanticHash(data []byte) string {
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return sha256hex(data)
	}
	if outbounds, ok := cfg["outbounds"].([]any); ok {
		for _, ob := range outbounds {
			obMap, ok := ob.(map[string]any)
			if !ok {
				continue
			}
			tls, ok := obMap["tls"].(map[string]any)
			if !ok {
				continue
			}
			// Strip server_name unconditionally — Marzban rotates it on all
			// outbound types (Reality and plain TLS alike) for anti-DPI.
			delete(tls, "server_name")
		}
	}
	normalized, err := json.Marshal(cfg)
	if err != nil {
		return sha256hex(data)
	}
	return sha256hex(normalized)
}

func writeFile(path, content string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
