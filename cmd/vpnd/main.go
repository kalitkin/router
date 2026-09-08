package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/kalitkin/router/internal/agent"
)

const (
	defaultDir     = "/etc/vpn"
	defaultBaseURL = "https://self-music.online"
)

func main() {
	dir := flag.String("dir", defaultDir, "credentials directory")
	flag.Parse()

	creds, err := loadCreds(*dir)
	if err != nil {
		log.Fatalf("vpnd: %v", err)
	}

	cfg := agent.Config{
		Dir:      *dir,
		Token:    creds.token,
		DeviceID: creds.deviceID,
		MAC:      creds.mac,
		Firmware: firmware(),
		BaseURL:  defaultBaseURL,
	}

	agent.New(cfg).Run()
}

type creds struct {
	token    string
	deviceID string
	mac      string
}

func loadCreds(dir string) (creds, error) {
	token, err := readFile(dir, "token")
	if err != nil || token == "" {
		return creds{}, fmt.Errorf("no token — device not registered")
	}
	deviceID, _ := readFile(dir, "device_id")
	mac, _ := readFile(dir, "mac")

	if mac == "" {
		mac = detectMAC()
	}
	return creds{token: token, deviceID: deviceID, mac: mac}, nil
}

func readFile(dir, name string) (string, error) {
	data, err := os.ReadFile(dir + "/" + name)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

var candidateIfaces = []string{"br-lan", "br0", "Bridge0", "eth0", "wan"}

func detectMAC() string {
	return detectMACFrom("/sys/class/net", candidateIfaces)
}

func detectMACFrom(sysClassNet string, ifaces []string) string {
	for _, iface := range ifaces {
		data, err := os.ReadFile(sysClassNet + "/" + iface + "/address")
		if err != nil {
			continue
		}
		mac := strings.TrimSpace(string(data))
		if mac != "" && mac != "00:00:00:00:00:00" {
			return mac
		}
	}
	return ""
}

const (
	openwrtReleasePath  = "/etc/openwrt_release"
	keeneticReleasePath = "/proc/sys/keenetic/release"
)

// firmware returns the router's firmware version string, or "" if neither
// platform's version source is present.
func firmware() string {
	return firmwareFrom(openwrtReleasePath, keeneticReleasePath)
}

func firmwareFrom(openwrtPath, keeneticPath string) string {
	if v := openwrtRelease(openwrtPath); v != "" {
		return v
	}
	return keeneticRelease(keeneticPath)
}

// openwrtRelease parses DISTRIB_RELEASE out of /etc/openwrt_release.
func openwrtRelease(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "DISTRIB_RELEASE=") {
			return strings.Trim(strings.TrimPrefix(line, "DISTRIB_RELEASE="), "'\"")
		}
	}
	return ""
}

// keeneticRelease reads KeeneticOS's version from /proc/sys/keenetic/release.
// This needs no admin credentials, unlike the RCI HTTP API — vpnd is never
// provisioned with the router's admin password.
func keeneticRelease(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}
