package agent

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func (a *Agent) reconcileLoop(ctx context.Context, configCh <-chan string) {
	ticker := time.NewTicker(reconcileInterval)
	defer ticker.Stop()

	// Apply config from disk on startup if we have one.
	a.applyFromDisk()

	for {
		select {
		case <-ctx.Done():
			return

		case subLink := <-configCh:
			a.log.Printf("reconcile: config update from heartbeat")
			if err := a.applySubLink(subLink); err != nil {
				a.log.Printf("reconcile: apply failed: %v", err)
			}

		case <-ticker.C:
			subLink := a.readSubLink()
			if subLink == "" {
				continue
			}
			a.log.Printf("reconcile: periodic check")
			if err := a.applySubLink(subLink); err != nil {
				a.log.Printf("reconcile: apply failed: %v", err)
			}
		}
	}
}

func (a *Agent) applySubLink(subLink string) error {
	a.mu.Lock()
	if a.safeMode {
		if time.Now().Before(a.safeModeUntil) {
			a.mu.Unlock()
			a.log.Println("reconcile: SAFE MODE active, skipping")
			return nil
		}
		a.safeMode = false
		a.rollbackCount = 0
		a.log.Println("reconcile: SAFE MODE lifted")
	}
	a.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	data, err := a.api.GetSingBoxConfig(ctx, subLink)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}

	hash := sha256hex(data)
	a.mu.Lock()
	if hash == a.appliedHash {
		a.mu.Unlock()
		return nil // nothing changed
	}
	a.mu.Unlock()

	a.log.Printf("reconcile: new config hash=%s…", hash[:12])

	// Backup current config before touching anything.
	if err := a.sb.Backup(); err != nil {
		a.log.Printf("reconcile: backup warning: %v", err)
	}

	if err := a.sb.Apply(data); err != nil {
		a.log.Printf("reconcile: apply error: %v — rolling back", err)
		return a.doRollback()
	}

	// Persist sub_link and applied hash.
	_ = writeFile(filepath.Join(a.cfg.Dir, "config"), subLink)
	_ = writeFile(filepath.Join(a.cfg.Dir, "applied_hash"), hash)

	a.mu.Lock()
	a.appliedHash = hash
	a.mu.Unlock()

	a.log.Printf("reconcile: applied config hash=%s…", hash[:12])
	return nil
}

func (a *Agent) applyFromDisk() {
	subLink := a.readSubLink()
	if subLink == "" {
		return
	}

	if a.sb.IsRunning() {
		a.log.Println("startup: VPN already running")
		if stored := a.readAppliedHash(); stored != "" {
			a.mu.Lock()
			a.appliedHash = stored
			a.mu.Unlock()
		}
		return
	}

	a.log.Println("startup: VPN not running, applying config from disk")
	if err := a.sb.Restart(); err != nil {
		a.log.Printf("startup: restart failed: %v", err)
	}
}

func (a *Agent) doRollback() error {
	a.mu.Lock()
	now := time.Now()
	if a.rollbackSince.IsZero() || now.Sub(a.rollbackSince) > rollbackWindow {
		a.rollbackCount = 0
		a.rollbackSince = now
	}
	a.rollbackCount++
	count := a.rollbackCount
	a.mu.Unlock()

	a.log.Printf("rollback #%d", count)

	if count > maxRollbacks {
		a.mu.Lock()
		a.safeMode = true
		a.safeModeUntil = time.Now().Add(safeModeWait)
		a.mu.Unlock()
		a.log.Printf("SAFE MODE: too many rollbacks (%d in %s), pausing reconcile for %s",
			count, rollbackWindow, safeModeWait)
		return fmt.Errorf("safe mode activated")
	}

	if err := a.sb.Rollback(); err != nil {
		return fmt.Errorf("rollback: %w", err)
	}
	a.log.Println("rollback: success")
	return nil
}

func (a *Agent) readSubLink() string {
	data, _ := os.ReadFile(filepath.Join(a.cfg.Dir, "config"))
	return string(data)
}

func (a *Agent) readAppliedHash() string {
	data, _ := os.ReadFile(filepath.Join(a.cfg.Dir, "applied_hash"))
	return string(data)
}

func sha256hex(data []byte) string {
	h := sha256.Sum256(data)
	return fmt.Sprintf("%x", h)
}

func writeFile(path, content string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
