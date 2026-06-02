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

func detectMAC() string {
	for _, iface := range []string{"br-lan", "eth0", "wan"} {
		data, err := os.ReadFile("/sys/class/net/" + iface + "/address")
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

func firmware() string {
	data, err := os.ReadFile("/etc/openwrt_release")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "DISTRIB_RELEASE=") {
			v := strings.Trim(strings.TrimPrefix(line, "DISTRIB_RELEASE="), "'\"")
			return v
		}
	}
	return ""
}
