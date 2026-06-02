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
		a.log.Println("circuit breaker: probing server")
	}

	req := api.HeartbeatReq{
		IP:              localIP(),
		FirmwareVersion: a.cfg.Firmware,
	}

	resp, err := a.api.Heartbeat(ctx, req)
	if err != nil {
		*consecutiveFails++
		if *consecutiveFails <= 5 {
			a.log.Printf("heartbeat fail #%d: %v", *consecutiveFails, err)
		}

		if *consecutiveFails >= circuitThreshold && !*circuitOpen {
			*circuitOpen = true
			*circuitOpenSince = time.Now()
			a.log.Printf("circuit breaker OPEN after %d failures", *consecutiveFails)
		}
		return
	}

	if *consecutiveFails > 0 {
		a.log.Printf("heartbeat recovered after %d failures", *consecutiveFails)
	}
	*consecutiveFails = 0
	if *circuitOpen {
		*circuitOpen = false
		a.log.Println("circuit breaker CLOSED")
	}

	if resp.Status == "DENY" {
		a.log.Println("device DENIED by server, stopping heartbeat")
		return
	}

	if resp.Config != "" {
		select {
		case configCh <- resp.Config:
		default:
			// Channel already has a pending update; drop duplicate.
		}
	}

	if resp.UpdateAvailable {
		a.log.Printf("OTA update available: %s — %s", resp.UpdateVersion, resp.UpdateURL)
	}
}
