package agent

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kalitkin/router/internal/api"
)

const (
	otaMarkerFile        = "ota_pending.json"
	otaAppliedFile       = "ota_applied_version"
	otaConfirmWindow     = 3 * time.Minute  // must see one successful heartbeat within this window post-update
	otaConfirmPoll       = 2 * time.Second
	otaMaxAttempts       = 3                // boot attempts before giving up and rolling back
	otaMinRetryInterval  = 1 * time.Hour    // backoff for the same server-advertised version
	otaDownloadTimeout   = 60 * time.Second
	otaSmokeTimeout      = 5 * time.Second
	otaMaxBinarySize     = 32 * 1024 * 1024 // real vpnd binaries are a few MB; this is a generous cap
	otaMaxChecksumBytes  = 256              // a sha256 hex digest is 64 bytes
)

var otaHTTPClient = &http.Client{
	Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}},
}

// otaMarker persists across the self-re-exec triggered by a successful
// binary swap. The freshly started (new) process finds it on disk and knows
// it must prove itself — one successful heartbeat — within otaConfirmWindow,
// or confirmPendingUpdate restores the previous binary and re-execs into it.
//
// Attempts survives across crash-restarts too: if the new binary dies before
// ever confirming, whatever supervises the process (procd on OpenWrt; nothing
// at all on Keenetic today — see files/S99vpnd) may start it again, and each
// boot with a still-pending marker increments Attempts until otaMaxAttempts
// forces a rollback instead of trying forever.
type otaMarker struct {
	FromVersion string    `json:"from_version"`
	ToVersion   string    `json:"to_version"`
	Attempts    int       `json:"attempts"`
	StartedAt   time.Time `json:"started_at"`
}

func otaMarkerPath(dir string) string  { return filepath.Join(dir, otaMarkerFile) }
func otaAppliedPath(dir string) string { return filepath.Join(dir, otaAppliedFile) }

func readOTAMarker(dir string) (*otaMarker, error) {
	data, err := os.ReadFile(otaMarkerPath(dir))
	if err != nil {
		return nil, err
	}
	var m otaMarker
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

func writeOTAMarker(dir string, m *otaMarker) error {
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return writeFile(otaMarkerPath(dir), string(data))
}

func clearOTAMarker(dir string) {
	_ = os.Remove(otaMarkerPath(dir))
}

func readAppliedOTAVersion(dir string) string {
	data, _ := os.ReadFile(otaAppliedPath(dir))
	return strings.TrimSpace(string(data))
}

// shouldAttemptUpdate is the pure decision at the heart of maybeStartUpdate,
// pulled out so it can be unit tested without goroutines, mutexes, or a real
// clock. It deliberately never compares resp.UpdateVersion against the
// client's own build version (cfg.Version / main.version): the two are not
// guaranteed to share a format (server might send "1.4.0", the client's own
// build version is a bare git SHA — see main.go). Instead, "already done" is
// tracked locally via appliedVersion, which stores the exact server string
// that was last successfully confirmed.
func shouldAttemptUpdate(resp *api.HeartbeatResp, appliedVersion string, inProgress, inSafeMode bool, lastVersion string, lastAttempt, now time.Time) bool {
	if !resp.UpdateAvailable || resp.UpdateVersion == "" || resp.UpdateURL == "" {
		return false
	}
	if resp.UpdateVersion == appliedVersion {
		return false
	}
	if inProgress || inSafeMode {
		return false
	}
	if lastVersion == resp.UpdateVersion && now.Sub(lastAttempt) < otaMinRetryInterval {
		return false
	}
	return true
}

// maybeStartUpdate is called after every heartbeat that reports
// update_available. It launches performUpdate in the background at most
// once at a time, backing off for otaMinRetryInterval per server-advertised
// version so a persistently failing download/verify/smoke-test doesn't hammer
// the CDN or churn the router every 45 seconds.
func (a *Agent) maybeStartUpdate(resp *api.HeartbeatResp) {
	appliedVersion := readAppliedOTAVersion(a.cfg.Dir)

	a.mu.Lock()
	inSafe := a.safeMode && time.Now().Before(a.safeModeUntil)
	canStart := shouldAttemptUpdate(resp, appliedVersion, a.otaInProgress, inSafe, a.otaLastVersion, a.otaLastAttempt, time.Now())
	if canStart {
		a.otaInProgress = true
		a.otaLastVersion = resp.UpdateVersion
		a.otaLastAttempt = time.Now()
	}
	a.mu.Unlock()

	if !canStart {
		return
	}

	toVersion, url := resp.UpdateVersion, resp.UpdateURL
	go func() {
		defer func() {
			a.mu.Lock()
			a.otaInProgress = false
			a.mu.Unlock()
		}()
		a.log.Printf("ota: update available (server version %q), starting", toVersion)
		if err := a.performUpdate(toVersion, url); err != nil {
			a.log.Printf("ota: update to %q failed: %v", toVersion, err)
		}
	}()
}

// performUpdate downloads, verifies, and smoke-tests the new binary, then
// atomically swaps it in (keeping exactly one previous version as a rollback
// target) and re-execs into it. Every step before the swap is side-effect
// free on failure: the currently running process and binary are untouched.
func (a *Agent) performUpdate(toVersion, url string) error {
	binPath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve own binary path: %w", err)
	}
	newPath := binPath + ".new"
	prevPath := binPath + ".prev"

	if err := downloadAndVerify(url, newPath); err != nil {
		os.Remove(newPath)
		return fmt.Errorf("download: %w", err)
	}

	if err := smokeTest(newPath); err != nil {
		os.Remove(newPath)
		return fmt.Errorf("smoke test: %w", err)
	}

	// Keep exactly one previous binary as a rollback target.
	os.Remove(prevPath)
	if err := os.Rename(binPath, prevPath); err != nil {
		os.Remove(newPath)
		return fmt.Errorf("backup current binary: %w", err)
	}
	if err := os.Rename(newPath, binPath); err != nil {
		// Must not leave the router with no binary at all.
		_ = os.Rename(prevPath, binPath)
		return fmt.Errorf("install new binary: %w", err)
	}

	marker := &otaMarker{FromVersion: a.cfg.Version, ToVersion: toVersion, Attempts: 1, StartedAt: time.Now()}
	if err := writeOTAMarker(a.cfg.Dir, marker); err != nil {
		a.log.Printf("ota: WARNING could not persist pending marker, rollback safety net is degraded: %v", err)
	}

	a.log.Printf("ota: installed %q, re-executing", toVersion)
	if err := syscallExec(binPath, os.Args, os.Environ()); err != nil {
		// exec() only replaces the process image on success — on failure the
		// old process (this one) is still alive and still running the old
		// code, it just now points at a binary we already renamed away. Undo
		// the swap immediately rather than leave that mismatch in place.
		a.log.Printf("ota: exec into new binary failed: %v — rolling back", err)
		clearOTAMarker(a.cfg.Dir)
		_ = os.Rename(prevPath, binPath)
		return fmt.Errorf("exec new binary: %w", err)
	}
	return nil // unreachable on success: the process image no longer exists
}

// confirmPendingUpdate runs once at startup. If a previous run's
// performUpdate left a pending marker, this process IS the newly installed
// binary — it must reach one successful heartbeat within otaConfirmWindow or
// get rolled back. Runs the wait in a goroutine so it never blocks startup.
func (a *Agent) confirmPendingUpdate() {
	marker, err := readOTAMarker(a.cfg.Dir)
	if err != nil {
		return // no pending update — ordinary startup
	}

	a.log.Printf("ota: resuming after update %q -> %q (boot attempt %d)", marker.FromVersion, marker.ToVersion, marker.Attempts)

	if marker.Attempts >= otaMaxAttempts {
		a.log.Printf("ota: %d failed boot attempts — giving up, rolling back to %q", marker.Attempts, marker.FromVersion)
		a.rollbackUpdate()
		return
	}

	marker.Attempts++
	if err := writeOTAMarker(a.cfg.Dir, marker); err != nil {
		a.log.Printf("ota: could not persist attempt count: %v", err)
	}

	a.mu.Lock()
	baseline := a.heartbeatOKCount
	a.mu.Unlock()

	toVersion := marker.ToVersion
	go func() {
		deadline := time.Now().Add(otaConfirmWindow)
		ticker := time.NewTicker(otaConfirmPoll)
		defer ticker.Stop()
		for time.Now().Before(deadline) {
			<-ticker.C
			a.mu.Lock()
			progressed := a.heartbeatOKCount > baseline
			a.mu.Unlock()
			if progressed {
				a.log.Printf("ota: update to %q confirmed", toVersion)
				_ = writeFile(otaAppliedPath(a.cfg.Dir), toVersion)
				clearOTAMarker(a.cfg.Dir)
				return
			}
		}
		a.log.Printf("ota: update to %q did not confirm within %s — rolling back", toVersion, otaConfirmWindow)
		a.rollbackUpdate()
	}()
}

// rollbackUpdate restores the previous binary (saved as <path>.prev during
// performUpdate) and re-execs into it. If there is nothing to restore (e.g.
// prev was already consumed by an even earlier rollback), it just clears the
// marker — there is no safe action left to take from here.
func (a *Agent) rollbackUpdate() {
	binPath, err := os.Executable()
	if err != nil {
		a.log.Printf("ota: rollback: resolve own binary path: %v", err)
		return
	}
	prevPath := binPath + ".prev"

	if _, err := os.Stat(prevPath); err != nil {
		a.log.Printf("ota: rollback: no previous binary available: %v", err)
		clearOTAMarker(a.cfg.Dir)
		return
	}
	if err := os.Rename(prevPath, binPath); err != nil {
		a.log.Printf("ota: rollback: restore previous binary: %v", err)
		return
	}
	clearOTAMarker(a.cfg.Dir)

	a.log.Println("ota: re-executing restored previous binary")
	if err := syscallExec(binPath, os.Args, os.Environ()); err != nil {
		a.log.Printf("ota: rollback: exec failed: %v — continuing on current process", err)
	}
}

// downloadAndVerify fetches url+".sha256" and url, checks the binary's
// sha256 against it, and writes it to destPath only once verified. The
// checksum sidecar is published by files/deploy-vpnd.sh next to every
// per-arch binary — this is a transport-integrity check (catches corruption
// and CDN/MITM tampering of the binary alone), not a signature: a compromised
// deploy pipeline could still publish a matching pair. See
// project_bypass_list_signing_gap for the same caveat on the bypass lists.
func downloadAndVerify(url, destPath string) error {
	ctx, cancel := context.WithTimeout(context.Background(), otaDownloadTimeout)
	defer cancel()

	wantHash, err := fetchChecksum(ctx, url+".sha256")
	if err != nil {
		return fmt.Errorf("fetch checksum: %w", err)
	}

	data, err := fetchBody(ctx, url, otaMaxBinarySize)
	if err != nil {
		return fmt.Errorf("fetch binary: %w", err)
	}
	if len(data) == 0 {
		return errors.New("empty binary download")
	}

	got := sha256.Sum256(data)
	gotHex := hex.EncodeToString(got[:])
	if !strings.EqualFold(gotHex, wantHash) {
		return fmt.Errorf("checksum mismatch: got %s want %s", gotHex, wantHash)
	}

	return os.WriteFile(destPath, data, 0755)
}

func fetchChecksum(ctx context.Context, url string) (string, error) {
	body, err := fetchBody(ctx, url, otaMaxChecksumBytes)
	if err != nil {
		return "", err
	}
	hash := strings.ToLower(strings.TrimSpace(string(body)))
	// Tolerate the common "sha256sum <file>" format ("<hash>  filename").
	if idx := strings.IndexAny(hash, " \t"); idx > 0 {
		hash = hash[:idx]
	}
	if len(hash) != 64 {
		return "", fmt.Errorf("unexpected checksum length %d", len(hash))
	}
	return hash, nil
}

func fetchBody(ctx context.Context, url string, maxBytes int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := otaHTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("response exceeds %d bytes", maxBytes)
	}
	return data, nil
}

// smokeTest runs the downloaded binary with -version before it ever touches
// the live install path. This is the cheapest possible check that the file
// is actually executable on this router's architecture — a wrong-arch or
// corrupted-but-checksum-matching (impossible, but defense in depth) binary
// fails here instead of after the swap, when the old process is already gone.
func smokeTest(path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), otaSmokeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "-version")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("run %s -version: %w — %s", path, err, out)
	}
	if len(strings.TrimSpace(string(out))) == 0 {
		return errors.New("empty -version output")
	}
	return nil
}
