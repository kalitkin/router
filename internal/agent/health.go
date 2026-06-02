package agent

import (
	"context"
	"time"
)

func (a *Agent) healthLoop(ctx context.Context) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	cycle := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cycle++
			if cycle%healEvery == 0 {
				a.checkHealth()
			}
		}
	}
}

func (a *Agent) checkHealth() {
	// L1: process alive?
	if !a.sb.IsRunning() {
		a.log.Println("health L1: sing-box process dead — restarting")
		if err := a.sb.Restart(); err != nil {
			a.log.Printf("health L1: restart failed: %v — rolling back", err)
			if err := a.doRollback(); err != nil {
				a.log.Printf("health L1: rollback failed: %v", err)
			}
		} else {
			a.log.Println("health L1: sing-box recovered")
		}
		return
	}

	// L2: Clash API alive?
	if !a.sb.IsAPIAlive() {
		a.log.Println("health L2: Clash API not responding — restarting sing-box")
		if err := a.sb.Restart(); err != nil {
			a.log.Printf("health L2: restart failed: %v", err)
		} else {
			a.log.Println("health L2: sing-box restarted")
		}
	}
}
