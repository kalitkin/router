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

func (a *Agent) heartbeatLoop(ctx context.Context, configCh chan<- string, cmdCh chan<- *Command) {
	consecutiveFails := 0
	circuitOpen := false
	circuitOpenSince := time.Time{}

	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	a.doHeartbeat(ctx, &consecutiveFails, &circuitOpen, &circuitOpenSince, configCh, cmdCh)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.doHeartbeat(ctx, &consecutiveFails, &circuitOpen, &circuitOpenSince, configCh, cmdCh)
		}
	}
}

func (a *Agent) doHeartbeat(
	ctx context.Context,
	consecutiveFails *int,
	circuitOpen *bool,
	circuitOpenSince *time.Time,
	configCh chan<- string,
	cmdCh chan<- *Command,
) {
	if *circuitOpen {
		if time.Since(*circuitOpenSince) < circuitCooldown {
			return
		}
		a.log.Println("heartbeat: circuit probing server")
	}

	// Collect current state to report.
	currentServer, _ := a.sb.CurrentServer()
	availableServers, _ := a.sb.ListServers()

	a.mu.Lock()
	cmdResult := a.lastCmdResult
	a.lastCmdResult = nil // clear — will be sent this heartbeat
	a.mu.Unlock()

	req := api.HeartbeatReq{
		IP:               localIP(),
		FirmwareVersion:  a.cfg.Firmware,
		CurrentServer:    currentServer,
		AvailableServers: availableServers,
		CommandResult:    toAPIResult(cmdResult),
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
			a.log.Printf("heartbeat: circuit OPEN after %d failures", *consecutiveFails)
		}
		// Put result back — don't lose it on transient failure.
		if cmdResult != nil {
			a.mu.Lock()
			if a.lastCmdResult == nil {
				a.lastCmdResult = cmdResult
			}
			a.mu.Unlock()
		}
		return
	}

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

	// New config from server → signal reconcile.
	if resp.Config != "" {
		select {
		case configCh <- resp.Config:
		default:
		}
	}

	// Incoming command → dispatch to commandLoop (dedup by ID).
	// lastCmdID is written only after successful enqueue so that a full channel
	// does not permanently suppress the command on the next heartbeat.
	if resp.Command != nil {
		a.mu.Lock()
		alreadyRan := a.lastCmdID == resp.Command.ID
		a.mu.Unlock()

		if !alreadyRan {
			cmd := fromAPICommand(resp.Command)
			select {
			case cmdCh <- cmd:
				a.mu.Lock()
				a.lastCmdID = resp.Command.ID
				a.mu.Unlock()
			default:
				a.log.Printf("heartbeat: command queue full, will retry next beat %s", cmd.ID)
			}
		}
	}

	if resp.UpdateAvailable {
		a.log.Printf("heartbeat: OTA available v%s — %s", resp.UpdateVersion, resp.UpdateURL)
	}
}

// ── type converters (api ↔ agent) ─────────────────────────────────────────────

func toAPIResult(r *CommandResult) *api.CommandResult {
	if r == nil {
		return nil
	}
	return &api.CommandResult{
		ID:      r.ID,
		Success: r.Success,
		Output:  r.Output,
		Error:   r.Error,
	}
}

func fromAPICommand(c *api.Command) *Command {
	return &Command{
		ID:        c.ID,
		Type:      c.Type,
		Params:    c.Params,
		ExpiresAt: c.ExpiresAt,
	}
}
