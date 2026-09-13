package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/kalitkin/router/internal/api"
)

func TestShouldAttemptUpdate(t *testing.T) {
	now := time.Now()
	baseResp := &api.HeartbeatResp{UpdateAvailable: true, UpdateVersion: "1.4.0", UpdateURL: "https://cdn/vpnd"}

	tests := []struct {
		name           string
		resp           *api.HeartbeatResp
		appliedVersion string
		inProgress     bool
		inSafeMode     bool
		lastVersion    string
		lastAttempt    time.Time
		want           bool
	}{
		{
			name: "no update advertised",
			resp: &api.HeartbeatResp{UpdateAvailable: false},
			want: false,
		},
		{
			name: "advertised but missing version",
			resp: &api.HeartbeatResp{UpdateAvailable: true, UpdateURL: "https://cdn/vpnd"},
			want: false,
		},
		{
			name: "advertised but missing url",
			resp: &api.HeartbeatResp{UpdateAvailable: true, UpdateVersion: "1.4.0"},
			want: false,
		},
		{
			name:           "already applied and confirmed this exact server version",
			resp:           baseResp,
			appliedVersion: "1.4.0",
			want:           false,
		},
		{
			name:       "an update is already in flight",
			resp:       baseResp,
			inProgress: true,
			want:       false,
		},
		{
			name:       "safe mode is active",
			resp:       baseResp,
			inSafeMode: true,
			want:       false,
		},
		{
			name:        "same version attempted recently — still in cooldown",
			resp:        baseResp,
			lastVersion: "1.4.0",
			lastAttempt: now.Add(-10 * time.Minute),
			want:        false,
		},
		{
			name:        "same version but cooldown has elapsed",
			resp:        baseResp,
			lastVersion: "1.4.0",
			lastAttempt: now.Add(-2 * time.Hour),
			want:        true,
		},
		{
			name:        "different version than last attempt — cooldown does not apply",
			resp:        baseResp,
			lastVersion: "1.3.9",
			lastAttempt: now.Add(-1 * time.Minute),
			want:        true,
		},
		{
			name: "fresh update, nothing in the way",
			resp: baseResp,
			want: true,
		},
		{
			name:           "client build version happens to differ from applied marker — irrelevant, only appliedVersion matters",
			resp:           baseResp,
			appliedVersion: "some-other-string-entirely",
			want:           true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shouldAttemptUpdate(tt.resp, tt.appliedVersion, tt.inProgress, tt.inSafeMode, tt.lastVersion, tt.lastAttempt, now)
			if got != tt.want {
				t.Errorf("shouldAttemptUpdate() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestOTAMarkerRoundTrip(t *testing.T) {
	dir := t.TempDir()

	if _, err := readOTAMarker(dir); err == nil {
		t.Fatal("readOTAMarker() on empty dir should error")
	}

	want := &otaMarker{FromVersion: "abc123", ToVersion: "1.4.0", Attempts: 2, StartedAt: time.Now().Truncate(time.Second)}
	if err := writeOTAMarker(dir, want); err != nil {
		t.Fatalf("writeOTAMarker() error = %v", err)
	}

	got, err := readOTAMarker(dir)
	if err != nil {
		t.Fatalf("readOTAMarker() error = %v", err)
	}
	if got.FromVersion != want.FromVersion || got.ToVersion != want.ToVersion || got.Attempts != want.Attempts {
		t.Errorf("readOTAMarker() = %+v, want %+v", got, want)
	}

	clearOTAMarker(dir)
	if _, err := readOTAMarker(dir); err == nil {
		t.Fatal("readOTAMarker() after clearOTAMarker() should error")
	}
}

func TestReadAppliedOTAVersion(t *testing.T) {
	dir := t.TempDir()

	if got := readAppliedOTAVersion(dir); got != "" {
		t.Errorf("readAppliedOTAVersion() on empty dir = %q, want empty", got)
	}

	if err := writeFile(otaAppliedPath(dir), "1.4.0\n"); err != nil {
		t.Fatalf("writeFile() error = %v", err)
	}
	if got := readAppliedOTAVersion(dir); got != "1.4.0" {
		t.Errorf("readAppliedOTAVersion() = %q, want %q", got, "1.4.0")
	}
}

func TestDownloadAndVerify(t *testing.T) {
	payload := []byte("fake-vpnd-binary-contents")
	sum := sha256.Sum256(payload)
	hexSum := hex.EncodeToString(sum[:])

	tests := []struct {
		name       string
		binaryBody []byte
		checksum   string
		wantErr    bool
	}{
		{
			name:       "matching checksum succeeds",
			binaryBody: payload,
			checksum:   hexSum,
			wantErr:    false,
		},
		{
			name:       "mismatched checksum is rejected",
			binaryBody: payload,
			checksum:   "0000000000000000000000000000000000000000000000000000000000000000",
			wantErr:    true,
		},
		{
			name:       "sha256sum-style checksum line (hash + filename) is tolerated",
			binaryBody: payload,
			checksum:   hexSum + "  vpnd\n",
			wantErr:    false,
		},
		{
			name:       "malformed checksum is rejected",
			binaryBody: payload,
			checksum:   "not-a-hash",
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/vpnd":
					w.Write(tt.binaryBody)
				case "/vpnd.sha256":
					w.Write([]byte(tt.checksum))
				default:
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer srv.Close()

			dest := filepath.Join(t.TempDir(), "vpnd.new")
			err := downloadAndVerify(srv.URL+"/vpnd", dest)
			if (err != nil) != tt.wantErr {
				t.Fatalf("downloadAndVerify() error = %v, wantErr %v", err, tt.wantErr)
			}
			if !tt.wantErr {
				got, readErr := os.ReadFile(dest)
				if readErr != nil {
					t.Fatalf("read downloaded file: %v", readErr)
				}
				if string(got) != string(payload) {
					t.Errorf("downloaded content = %q, want %q", got, payload)
				}
			}
		})
	}
}

func TestDownloadAndVerifyMissingChecksum(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	dest := filepath.Join(t.TempDir(), "vpnd.new")
	if err := downloadAndVerify(srv.URL+"/vpnd", dest); err == nil {
		t.Fatal("downloadAndVerify() with missing checksum endpoint should error")
	}
	if _, err := os.Stat(dest); err == nil {
		t.Error("downloadAndVerify() should not write the destination file when verification fails")
	}
}

func TestSmokeTest(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("smokeTest execs a #!/bin/sh script; only meaningful on the actual deploy target (linux)")
	}

	t.Run("valid binary prints something and exits 0", func(t *testing.T) {
		script := filepath.Join(t.TempDir(), "fake-vpnd")
		if err := os.WriteFile(script, []byte("#!/bin/sh\necho 1.4.0\n"), 0755); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
		if err := smokeTest(script); err != nil {
			t.Errorf("smokeTest() error = %v, want nil", err)
		}
	})

	t.Run("non-zero exit is rejected", func(t *testing.T) {
		script := filepath.Join(t.TempDir(), "fake-vpnd")
		if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 1\n"), 0755); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
		if err := smokeTest(script); err == nil {
			t.Error("smokeTest() error = nil, want error for non-zero exit")
		}
	})

	t.Run("silent success is rejected", func(t *testing.T) {
		script := filepath.Join(t.TempDir(), "fake-vpnd")
		if err := os.WriteFile(script, []byte("#!/bin/sh\ntrue\n"), 0755); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
		if err := smokeTest(script); err == nil {
			t.Error("smokeTest() error = nil, want error for empty output")
		}
	})
}
