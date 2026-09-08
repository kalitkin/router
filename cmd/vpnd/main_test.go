package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFirmwareFrom(t *testing.T) {
	tests := []struct {
		name          string
		openwrtBody   string
		writeOpenwrt  bool
		keeneticBody  string
		writeKeenetic bool
		want          string
	}{
		{
			name:         "openwrt release present",
			openwrtBody:  "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='24.10'\nDISTRIB_ARCH='mipsel'\n",
			writeOpenwrt: true,
			want:         "24.10",
		},
		{
			name:          "keenetic release present, no openwrt file",
			writeKeenetic: true,
			keeneticBody:  "5.0.12\n",
			want:          "5.0.12",
		},
		{
			name:         "openwrt file present but no DISTRIB_RELEASE line",
			openwrtBody:  "DISTRIB_ID='OpenWrt'\n",
			writeOpenwrt: true,
			want:         "",
		},
		{
			name: "neither file present",
			want: "",
		},
		{
			name:          "openwrt takes precedence over keenetic",
			openwrtBody:   "DISTRIB_RELEASE='24.10'\n",
			writeOpenwrt:  true,
			keeneticBody:  "5.0.12\n",
			writeKeenetic: true,
			want:          "24.10",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			openwrtPath := filepath.Join(dir, "openwrt_release")
			keeneticPath := filepath.Join(dir, "keenetic_release")

			if tt.writeOpenwrt {
				if err := os.WriteFile(openwrtPath, []byte(tt.openwrtBody), 0644); err != nil {
					t.Fatalf("write openwrt fixture: %v", err)
				}
			}
			if tt.writeKeenetic {
				if err := os.WriteFile(keeneticPath, []byte(tt.keeneticBody), 0644); err != nil {
					t.Fatalf("write keenetic fixture: %v", err)
				}
			}

			got := firmwareFrom(openwrtPath, keeneticPath)
			if got != tt.want {
				t.Errorf("firmwareFrom() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestDetectMAC(t *testing.T) {
	// detectMAC reads real /sys/class/net paths — on a dev machine none of
	// the router interface names exist, so it must fail closed to "".
	if got := detectMAC(); got != "" {
		t.Errorf("detectMAC() on non-router host = %q, want empty", got)
	}
}
