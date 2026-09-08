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

func TestDetectMACFrom(t *testing.T) {
	ifaces := []string{"br-lan", "br0", "eth0"}

	tests := []struct {
		name  string
		setup func(sysClassNet string)
		want  string
	}{
		{
			name:  "no interfaces present",
			setup: func(string) {},
			want:  "",
		},
		{
			name: "first matching interface wins",
			setup: func(dir string) {
				writeIfaceAddr(t, dir, "br-lan", "aa:bb:cc:dd:ee:01")
				writeIfaceAddr(t, dir, "eth0", "aa:bb:cc:dd:ee:02")
			},
			want: "aa:bb:cc:dd:ee:01",
		},
		{
			name: "skips zero MAC and falls through to next candidate",
			setup: func(dir string) {
				writeIfaceAddr(t, dir, "br-lan", "00:00:00:00:00:00")
				writeIfaceAddr(t, dir, "eth0", "aa:bb:cc:dd:ee:02")
			},
			want: "aa:bb:cc:dd:ee:02",
		},
		{
			name: "skips empty address file",
			setup: func(dir string) {
				writeIfaceAddr(t, dir, "br-lan", "")
				writeIfaceAddr(t, dir, "eth0", "aa:bb:cc:dd:ee:02")
			},
			want: "aa:bb:cc:dd:ee:02",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			tt.setup(dir)

			got := detectMACFrom(dir, ifaces)
			if got != tt.want {
				t.Errorf("detectMACFrom() = %q, want %q", got, tt.want)
			}
		})
	}
}

func writeIfaceAddr(t *testing.T, sysClassNet, iface, addr string) {
	t.Helper()
	ifaceDir := filepath.Join(sysClassNet, iface)
	if err := os.MkdirAll(ifaceDir, 0755); err != nil {
		t.Fatalf("mkdir %s: %v", ifaceDir, err)
	}
	if err := os.WriteFile(filepath.Join(ifaceDir, "address"), []byte(addr+"\n"), 0644); err != nil {
		t.Fatalf("write address: %v", err)
	}
}
