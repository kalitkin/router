package agent

import (
	"context"
	"time"
)

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
			// Reset L2 counter — the process was just (re)started, Clash API
			// needs a moment to come up. A stale counter would trigger an
			// unnecessary L2 restart on the very next health tick.
			a.mu.Lock()
			a.l2FailCount = 0
			a.mu.Unlock()
		}
		return
	}

	// L2: Clash API alive?
	// Require l2RestartThreshold consecutive failures before restarting —
	// a single slow response under swap pressure is not a real failure.
	if !a.sb.IsAPIAlive() {
		a.mu.Lock()
		a.l2FailCount++
		count := a.l2FailCount
		a.mu.Unlock()
		a.log.Printf("health L2: Clash API not responding (%d/%d)", count, l2RestartThreshold)
		if count >= l2RestartThreshold {
			a.mu.Lock()
			a.l2FailCount = 0
			a.mu.Unlock()
			a.log.Println("health L2: threshold reached — restarting")
			if err := a.sb.Restart(); err != nil {
				a.log.Printf("health L2: restart failed: %v", err)
			} else {
				a.log.Println("health L2: sing-box restarted")
			}
		}
	} else {
		a.mu.Lock()
		a.l2FailCount = 0
		a.mu.Unlock()
	}
}
