package agent

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	memWatchInterval = 5 * time.Minute
	memAvailableMin  = 12 * 1024 // kB — restart if MemAvailable < 12 MB
	singboxRSSMax    = 22 * 1024 // kB — restart if sing-box RSS > 22 MB (normal baseline is 18-21 MB)
	maxSingboxUptime = 24 * time.Hour
	memWatchCooldown = 15 * time.Minute // min interval between memwatch-triggered restarts
)

func (a *Agent) memWatchLoop(ctx context.Context) {
	ticker := time.NewTicker(memWatchInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.checkMemory()
		}
	}
}

func (a *Agent) checkMemory() {
	a.mu.Lock()
	inSafe := a.safeMode && time.Now().Before(a.safeModeUntil)
	lastRestart := a.lastMemRestart
	singboxStart := a.singboxStartedAt
	a.mu.Unlock()

	if inSafe {
		return
	}
	if !lastRestart.IsZero() && time.Since(lastRestart) < memWatchCooldown {
		return
	}

	reason := ""

	if avail, err := readMemAvailable(); err == nil && avail < memAvailableMin {
		reason = fmt.Sprintf("low MemAvailable %dkB", avail)
	}

	if reason == "" {
		if pid, err := singboxPID(); err == nil {
			if rss, err := readVmRSS(pid); err == nil && rss > singboxRSSMax {
				reason = fmt.Sprintf("high RSS %dkB", rss)
			}
		}
	}

	if reason == "" && !singboxStart.IsZero() && time.Since(singboxStart) > maxSingboxUptime {
		reason = fmt.Sprintf("scheduled restart (uptime %s)", time.Since(singboxStart).Round(time.Minute))
	}

	if reason == "" {
		return
	}

	a.log.Printf("memwatch: restarting sing-box (%s)", reason)
	if err := a.sb.Restart(); err != nil {
		a.log.Printf("memwatch: restart failed: %v", err)
		return
	}
	a.log.Println("memwatch: sing-box restarted OK")
	a.restoreServer()

	now := time.Now()
	a.mu.Lock()
	a.singboxStartedAt = now
	a.lastMemRestart = now
	a.l2FailCount = 0
	a.mu.Unlock()
}

// readMemAvailable returns MemAvailable from /proc/meminfo in kB.
func readMemAvailable() (int, error) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "MemAvailable:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				return strconv.Atoi(fields[1])
			}
		}
	}
	return 0, fmt.Errorf("MemAvailable not found in /proc/meminfo")
}

// readVmRSS returns VmRSS of a process in kB.
func readVmRSS(pid string) (int, error) {
	f, err := os.Open("/proc/" + pid + "/status")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "VmRSS:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				return strconv.Atoi(fields[1])
			}
		}
	}
	return 0, fmt.Errorf("VmRSS not found in /proc/%s/status", pid)
}

// singboxPID returns the PID of the running sing-box process.
func singboxPID() (string, error) {
	out, err := exec.Command("pgrep", "sing-box").Output()
	if err != nil {
		return "", fmt.Errorf("pgrep sing-box: %w", err)
	}
	pid := strings.TrimSpace(string(out))
	if pid == "" {
		return "", fmt.Errorf("sing-box not running")
	}
	// pgrep may return multiple lines; take the first.
	if i := strings.IndexByte(pid, '\n'); i >= 0 {
		pid = pid[:i]
	}
	return pid, nil
}
