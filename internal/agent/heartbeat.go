package agent

import (
	"context"
	"time"

	"github.com/kalitkin/router/internal/api"
)

const (
	pingInterval     = 45 * time.Second
	pingRetryDelay   = 10 * time.Second
	circuitThreshold = 7
	circuitCooldown  = 5 * time.Minute
)

func (a *Agent) heartbeatLoop(ctx context.Context, configCh chan<- string) {
	consecutiveFails := 0
	circuitOpen := false
	circuitOpenSince := time.Time{}

	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	// Run immediately on start.
	a.doHeartbeat(ctx, &consecutiveFails, &circuitOpen, &circuitOpenSince, configCh)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.doHeartbeat(ctx, &consecutiveFails, &circuitOpen, &circuitOpenSince, configCh)
		}
	}
}

func (a *Agent) doHeartbeat(
	ctx context.Context,
	consecutiveFails *int,
	circuitOpen *bool,
	circuitOpenSince *time.Time,
	configCh chan<- string,
) {
	if *circuitOpen {
		if time.Since(*circuitOpenSince) < circuitCooldown {
			return
		}
		a.log.Println("heartbeat: circuit probing server")
	}

	resp, err := a.api.Heartbeat(ctx, api.HeartbeatReq{
		IP:              localIP(),
		FirmwareVersion: a.cfg.Firmware,
	})
	if err != nil {
		*consecutiveFails++
		if *consecutiveFails <= 5 {
			a.log.Printf("heartbeat fail #%d: %v", *consecutiveFails, err)
		}
		if *consecutiveFails >= circuitThreshold && !*circuitOpen {
			*circuitOpen = true
			*circuitOpenSince = time.Now()
			a.log.Printf("heartbeat: circuit OPEN after %d failures", *consecutiveFails)
		}
		return
	}

	// Success — reset failure tracking.
	if *consecutiveFails > 0 {
		a.log.Printf("heartbeat: recovered after %d failures", *consecutiveFails)
	}
	*consecutiveFails = 0
	if *circuitOpen {
		*circuitOpen = false
		a.log.Println("heartbeat: circuit CLOSED")
	}

	if resp.Status == "DENY" {
		a.log.Println("heartbeat: device DENIED by server")
		return
	}

	if resp.Config != "" {
		// Last-write-wins: drain stale value before sending new one.
		select {
		case <-configCh:
		default:
		}
		select {
		case configCh <- resp.Config:
		default:
		}
	}

	if resp.UpdateAvailable {
		a.log.Printf("heartbeat: OTA available v%s — %s", resp.UpdateVersion, resp.UpdateURL)
	}
}
