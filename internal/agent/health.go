package agent

import (
	"context"
	"path/filepath"
	"time"
)

const l3FailThreshold = 2

func (a *Agent) healthLoop(ctx context.Context) {
	ticker := time.NewTicker(pingInterval * healEvery)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.checkHealth()
		}
	}
}

func (a *Agent) checkHealth() {
	// Do not interfere while safe mode is active.
	a.mu.Lock()
	inSafe := a.safeMode && time.Now().Before(a.safeModeUntil)
	a.mu.Unlock()
	if inSafe {
		return
	}

	// L1: process alive?
	if !a.sb.IsRunning() {
		a.log.Println("health L1: sing-box dead — restarting")
		if err := a.sb.Restart(); err != nil {
			a.log.Printf("health L1: restart failed: %v — rolling back", err)
			if err := a.doRollback(); err != nil {
				a.log.Printf("health L1: rollback failed: %v", err)
			}
		} else {
			a.log.Println("health L1: sing-box recovered")
			a.restoreServer()
			a.noteRestart()
		}
		return
	}

	// L2: Clash API alive?
	if !a.sb.IsAPIAlive() {
		a.mu.Lock()
		a.l2FailCount++
		count := a.l2FailCount
		a.mu.Unlock()
		a.log.Printf("health L2: Clash API not responding (%d/%d)", count, l2RestartThreshold)
		if count >= l2RestartThreshold {
			a.log.Println("health L2: threshold reached — restarting")
			if err := a.sb.Restart(); err != nil {
				a.log.Printf("health L2: restart failed: %v", err)
			} else {
				a.log.Println("health L2: sing-box restarted")
				a.restoreServer()
				a.noteRestart()
			}
		}
		return
	}

	// L2 passed: API alive, reset counter.
	a.mu.Lock()
	a.l2FailCount = 0
	a.mu.Unlock()

	// L3: VPN server reachability via Clash API delay test.
	// If the selected server is unreachable, auto-switch to a working one.
	a.checkL3Health()
}

// checkL3Health tests whether the currently selected VPN server can reach the
// internet. On two consecutive failures it searches for a working server and
// switches automatically — providing fallback when the user picks a dead server.
// The result is also cached in lastConnectOK/lastConnRTTMs for HEALTH-01 heartbeat reporting.
func (a *Agent) checkL3Health() {
	current, err := a.sb.CurrentServer()
	if err != nil || current == "" {
		return
	}

	delay, err := a.sb.TestServerDelay(current)

	// HEALTH-01: cache connectivity result for heartbeat health signal.
	{
		ok := err == nil
		a.mu.Lock()
		a.lastConnectOK = &ok
		if ok && delay > 0 {
			a.lastConnRTTMs = delay
		}
		a.mu.Unlock()
	}

	if err != nil {
		a.mu.Lock()
		a.l3FailCount++
		count := a.l3FailCount
		a.mu.Unlock()
		a.log.Printf("health L3: server %q unreachable (%d/%d): %v", current, count, l3FailThreshold, err)

		if count < l3FailThreshold {
			return
		}

		a.log.Printf("health L3: threshold reached, searching for working server...")
		working, err := a.sb.FindWorkingServer()
		if err != nil {
			a.log.Printf("health L3: no working server: %v", err)
			return
		}

		if working == current {
			a.log.Printf("health L3: current server %q reachable again", current)
		} else {
			if err := a.sb.SwitchServer(working); err != nil {
				a.log.Printf("health L3: switch to %q failed: %v", working, err)
				return
			}
			_ = writeFile(filepath.Join(a.cfg.Dir, "current_server"), working)
			a.log.Printf("health L3: switched to %q (was %q, unreachable)", working, current)
		}

		a.mu.Lock()
		a.l3FailCount = 0
		a.mu.Unlock()
	} else {
		a.mu.Lock()
		a.l3FailCount = 0
		a.mu.Unlock()
	}
}
