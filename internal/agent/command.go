package agent

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// Command is an instruction sent from the server via heartbeat response.
// Designed for easy extension: add new types without changing the transport.
type Command struct {
	ID        string            `json:"id"`                   // UUID — prevents re-execution
	Type      string            `json:"type"`                 // switch|restart|update|status
	Params    map[string]string `json:"params,omitempty"`     // type-specific parameters
	ExpiresAt int64             `json:"expires_at,omitempty"` // unix timestamp, 0 = no expiry
}

// CommandResult is included in the next heartbeat request so the server
// knows whether the command succeeded.
type CommandResult struct {
	ID      string            `json:"id"`
	Success bool              `json:"success"`
	Output  map[string]string `json:"output,omitempty"`
	Error   string            `json:"error,omitempty"`
}

func (c *Command) expired() bool {
	return c.ExpiresAt > 0 && time.Now().Unix() > c.ExpiresAt
}

// executeCommand runs the command and returns its result.
// Execution is synchronous but non-blocking for the heartbeat loop —
// called in a separate goroutine from heartbeat.go.
func (a *Agent) executeCommand(cmd *Command) CommandResult {
	if cmd.expired() {
		a.log.Printf("command %s (%s): expired, skipping", cmd.ID, cmd.Type)
		return CommandResult{ID: cmd.ID, Success: false, Error: "command expired"}
	}

	a.log.Printf("command %s: executing %s %v", cmd.ID, cmd.Type, cmd.Params)

	var err error
	output := map[string]string{}

	switch cmd.Type {

	case "switch":
		server := cmd.Params["server"]
		if server == "" {
			return failResult(cmd.ID, "missing param: server")
		}
		if err = a.sb.SwitchServer(server); err != nil {
			return failResult(cmd.ID, err.Error())
		}
		output["server"] = server
		a.log.Printf("command %s: switched to %s", cmd.ID, server)

	case "restart":
		if err = a.sb.Restart(); err != nil {
			return failResult(cmd.ID, err.Error())
		}
		a.log.Printf("command %s: sing-box restarted", cmd.ID)

	case "update":
		select {
		case a.forceReconcile <- struct{}{}:
			a.log.Printf("command %s: forced reconcile", cmd.ID)
		default:
			return failResult(cmd.ID, "reconcile already in progress")
		}

	case "status":
		server, _ := a.sb.CurrentServer()
		servers, _ := a.sb.ListServers()
		output["running"] = boolStr(a.sb.IsRunning())
		output["api_alive"] = boolStr(a.sb.IsAPIAlive())
		output["current_server"] = server
		output["servers"] = strings.Join(servers, ",")
		a.log.Printf("command %s: status collected", cmd.ID)

	default:
		return failResult(cmd.ID, fmt.Sprintf("unknown command type: %s", cmd.Type))
	}

	return CommandResult{ID: cmd.ID, Success: true, Output: output}
}

// commandLoop waits for commands from heartbeat and executes them.
// Runs as a separate goroutine so command execution never blocks heartbeat.
func (a *Agent) commandLoop(ctx context.Context, cmdCh <-chan *Command) {
	for {
		select {
		case <-ctx.Done():
			return
		case cmd := <-cmdCh:
			result := a.executeCommand(cmd)
			a.mu.Lock()
			a.lastCmdResult = &result
			a.mu.Unlock()
		}
	}
}

func failResult(id, msg string) CommandResult {
	return CommandResult{ID: id, Success: false, Error: msg}
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
