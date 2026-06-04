package singbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	clashAPIURL    = "http://127.0.0.1:9090"
	configPath     = "/etc/sing-box/config.json"
	backupSuffix   = ".bak"
	restartTimeout = 15 * time.Second
	apiTimeout     = 8 * time.Second
	selectorTag    = "proxy" // outbound selector tag in Marzban-generated sing-box config

	tproxyPort   = 7893          // sing-box TPROXY inbound port
	tproxyFwmark = "0x1"         // fwmark set on packets to intercept
	tproxyTable  = "100"         // routing table: local 0.0.0.0/0 dev lo
	bypassFwmark = "0x64"        // sing-box outbound mark → bypasses TPROXY
	nftTable     = "vpnbot"      // nftables table name
	vpsIPsPath   = "/etc/vpn/vps_ips" // VPN server IPs extracted from config
)

// Manager controls the sing-box process lifecycle.
// All public methods are safe for concurrent use.
type Manager struct {
	configPath  string
	clashURL    string
	httpClient  *http.Client
	delayClient *http.Client // longer timeout for server delay/connectivity tests
	mu          sync.Mutex  // serializes Apply/Restart/Rollback
	log         *log.Logger
}

func NewManager() *Manager {
	return &Manager{
		configPath:  configPath,
		clashURL:    clashAPIURL,
		httpClient:  &http.Client{Timeout: apiTimeout},
		delayClient: &http.Client{Timeout: 15 * time.Second},
		log:         log.New(os.Stderr, "[singbox] ", log.LstdFlags),
	}
}

// HasConfig reports whether a config file exists and is non-empty.
func (m *Manager) HasConfig() bool {
	info, err := os.Stat(m.configPath)
	return err == nil && info.Size() > 0
}

// Apply writes a new config and attempts hot reload, falling back to restart.
// Thread-safe: only one Apply/Restart/Rollback runs at a time.
func (m *Manager) Apply(data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	patched, vpsIPs, err := patchRouterConfig(data)
	if err != nil {
		return fmt.Errorf("patch config: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(m.configPath), 0755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	if err := writeAtomic(m.configPath, patched); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	if err := saveVPSIPs(vpsIPs); err != nil {
		m.log.Printf("warning: save vps_ips: %v", err)
	}

	// Level 1: hot reload via Clash API.
	if err := m.reloadLocked(patched); err == nil {
		m.updateVPSNftset(vpsIPs)
		return nil
	}

	// Level 2: service restart.
	return m.restartLocked()
}

// Restart restarts sing-box via init.d. Thread-safe.
func (m *Manager) Restart() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.restartLocked()
}

// Backup copies current config.json to config.json.bak atomically.
func (m *Manager) Backup() error {
	data, err := os.ReadFile(m.configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("backup read: %w", err)
	}
	return writeAtomic(m.configPath+backupSuffix, data)
}

// Rollback restores config from .bak and restarts sing-box. Thread-safe.
func (m *Manager) Rollback() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	bak := m.configPath + backupSuffix
	data, err := os.ReadFile(bak)
	if err != nil {
		return fmt.Errorf("no backup available: %w", err)
	}
	if err := writeAtomic(m.configPath, data); err != nil {
		return fmt.Errorf("rollback write: %w", err)
	}
	return m.restartLocked()
}

// SwitchServer selects an outbound in the sing-box selector via Clash API.
// No restart required — change is immediate.
func (m *Manager) SwitchServer(server string) error {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	body, _ := json.Marshal(map[string]string{"name": server})
	req, err := http.NewRequestWithContext(ctx, http.MethodPut,
		m.clashURL+"/proxies/"+selectorTag, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("clash API: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("switch server %q: HTTP %d", server, resp.StatusCode)
	}
	return nil
}

// CurrentServer returns the currently selected outbound in the selector.
// Returns ("", nil) when sing-box is not running or Clash API is unreachable.
func (m *Manager) CurrentServer() (string, error) {
	info, err := m.proxyInfo()
	if err != nil {
		return "", err
	}
	return info.Now, nil
}

// ListServers returns all outbounds available in the selector.
func (m *Manager) ListServers() ([]string, error) {
	info, err := m.proxyInfo()
	if err != nil {
		return nil, err
	}
	return info.All, nil
}

// TestServerDelay measures round-trip delay to the test URL via the named proxy.
// Calls Clash API /proxies/{name}/delay — blocks until the test finishes (≤10 s).
// Returns (delayMs, nil) on success; (0, err) if the server is unreachable.
func (m *Manager) TestServerDelay(serverName string) (int, error) {
	const (
		testURL      = "http://cp.cloudflare.com/generate_204"
		testTimeout  = 10000 // ms — passed to Clash API
	)

	params := url.Values{}
	params.Set("url", testURL)
	params.Set("timeout", fmt.Sprintf("%d", testTimeout))
	apiURL := fmt.Sprintf("%s/proxies/%s/delay?%s",
		m.clashURL, url.PathEscape(serverName), params.Encode())

	req, err := http.NewRequest(http.MethodGet, apiURL, nil)
	if err != nil {
		return 0, err
	}

	resp, err := m.delayClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("delay test request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		var msg struct {
			Message string `json:"message"`
		}
		json.Unmarshal(body, &msg) //nolint:errcheck
		return 0, fmt.Errorf("server %q unreachable (HTTP %d): %s", serverName, resp.StatusCode, msg.Message)
	}

	var result struct {
		Delay int `json:"delay"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return 0, fmt.Errorf("decode delay response: %w", err)
	}
	return result.Delay, nil
}

// FindWorkingServer tests all available servers and returns the first reachable one.
// The current server is tried last to prefer switching away from the failing one.
// Returns ("", err) if no server responds within timeout.
func (m *Manager) FindWorkingServer() (string, error) {
	servers, err := m.ListServers()
	if err != nil {
		return "", fmt.Errorf("list servers: %w", err)
	}
	if len(servers) == 0 {
		return "", fmt.Errorf("no servers in config")
	}

	current, _ := m.CurrentServer()

	// Build test order: non-current first, then current as last resort.
	order := make([]string, 0, len(servers))
	for _, s := range servers {
		if s != current {
			order = append(order, s)
		}
	}
	if current != "" {
		order = append(order, current)
	}

	for _, s := range order {
		if d, err := m.TestServerDelay(s); err == nil {
			m.log.Printf("connectivity: server %q reachable (%d ms)", s, d)
			return s, nil
		}
	}
	return "", fmt.Errorf("no reachable server found among %d candidates", len(servers))
}

func (m *Manager) proxyInfo() (*clashProxyResp, error) {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		m.clashURL+"/proxies/"+selectorTag, nil)
	if err != nil {
		return nil, err
	}

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("clash API: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("proxy info: HTTP %d", resp.StatusCode)
	}

	var info clashProxyResp
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("decode proxy info: %w", err)
	}
	return &info, nil
}

type clashProxyResp struct {
	Now string   `json:"now"`
	All []string `json:"all"`
}

// IsRunning returns true if a sing-box process is alive.
func (m *Manager) IsRunning() bool {
	// pgrep without -x for busybox compatibility.
	return exec.Command("pgrep", "sing-box").Run() == nil
}

// IsAPIAlive returns true if the Clash API responds.
func (m *Manager) IsAPIAlive() bool {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.clashURL+"/version", nil)
	if err != nil {
		return false
	}
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode == http.StatusOK
}

// ── internal (caller must hold m.mu) ─────────────────────────────────────────

func (m *Manager) reloadLocked(configData []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPut,
		m.clashURL+"/configs?force=true", bytes.NewReader(configData))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("clash API: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("clash reload: HTTP %d", resp.StatusCode)
	}
	return nil
}

func (m *Manager) restartLocked() error {
	cmd := exec.Command("/etc/init.d/sing-box", "restart")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("sing-box restart: %w — %s", err, out)
	}

	deadline := time.Now().Add(restartTimeout)
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		if m.IsRunning() {
			if err := m.SetupRouting(); err != nil {
				m.log.Printf("routing setup after restart: %v", err)
			}
			return nil
		}
	}
	return fmt.Errorf("sing-box did not start within %s", restartTimeout)
}

// ReapplyPatch re-applies patchRouterConfig to the on-disk config.json.
// If patches changed (e.g. after a vpnd upgrade), it restarts sing-box.
// Returns true if a restart was performed (SetupRouting already called inside).
func (m *Manager) ReapplyPatch() (bool, error) {
	data, err := os.ReadFile(m.configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("read config: %w", err)
	}

	patched, vpsIPs, err := patchRouterConfig(data)
	if err != nil {
		return false, fmt.Errorf("patch: %w", err)
	}

	if bytes.Equal(data, patched) {
		return false, nil
	}

	m.log.Println("reapply: config changed after re-patch (vpnd upgrade?), restarting")

	m.mu.Lock()
	defer m.mu.Unlock()

	if err := writeAtomic(m.configPath, patched); err != nil {
		return false, fmt.Errorf("write: %w", err)
	}
	if err := saveVPSIPs(vpsIPs); err != nil {
		m.log.Printf("warning: save vps_ips: %v", err)
	}
	return true, m.restartLocked()
}

// ── routing ───────────────────────────────────────────────────────────────────

// SetupRouting waits for the TPROXY port to be ready, then installs nftables
// rules and ip rules for kernel-level transparent proxying.
//
// Routing scheme:
//   - nftables inet vpnbot/mangle_pre: br-lan traffic → TPROXY port 7893
//   - ip rule prio 100: fwmark 0x1 → table 100 (TPROXY mark → loopback delivery)
//   - ip rule prio 500: fwmark 0x64 → main (sing-box outbound bypasses TPROXY)
//   - ip route table 100: local 0.0.0.0/0 dev lo (kernel delivers to tproxy socket)
func (m *Manager) SetupRouting() error {
	const waitTimeout = 15 * time.Second

	// Wait for sing-box TPROXY port to be ready.
	addr := fmt.Sprintf("127.0.0.1:%d", tproxyPort)
	deadline := time.Now().Add(waitTimeout)
	for {
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("tproxy port %d did not open within %s", tproxyPort, waitTimeout)
		}
		time.Sleep(500 * time.Millisecond)
	}

	// Load kernel modules (non-fatal: may already be built-in or loaded by opkg).
	exec.Command("modprobe", "nft_tproxy").Run()
	exec.Command("modprobe", "nft_socket").Run()

	vpsIPs := loadVPSIPs()

	// Flush stale nftables table (idempotent).
	exec.Command("nft", "delete", "table", "inet", nftTable).Run()

	// Remove stale ip rules at our priorities (and old TUN-mode prio 2022).
	for _, prio := range []string{"100", "500", "2022"} {
		exec.Command("ip", "rule", "del", "priority", prio).Run()
	}
	exec.Command("ip", "route", "flush", "table", tproxyTable).Run()
	exec.Command("ip", "route", "flush", "table", "2022").Run()

	// BusyBox ip(8) requires routing table names in /etc/iproute2/rt_tables.
	const rtTablesPath = "/etc/iproute2/rt_tables"
	if rtData, err := os.ReadFile(rtTablesPath); err == nil {
		if !bytes.Contains(rtData, []byte(tproxyTable+"\t")) {
			if f, err := os.OpenFile(rtTablesPath, os.O_APPEND|os.O_WRONLY, 0644); err == nil {
				fmt.Fprintf(f, "%s\ttproxy\n", tproxyTable)
				f.Close()
			}
		}
	}

	// Loopback route: TPROXY-marked packets are delivered to the local tproxy socket.
	if out, err := exec.Command(
		"ip", "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", tproxyTable,
	).CombinedOutput(); err != nil {
		return fmt.Errorf("ip route add local dev lo table %s: %w — %s", tproxyTable, err, out)
	}

	exec.Command("ip", "rule", "add", "fwmark", tproxyFwmark, "priority", "100", "lookup", tproxyTable).Run()
	exec.Command("ip", "rule", "add", "fwmark", bypassFwmark, "priority", "500", "lookup", "main").Run()

	// Apply nftables table atomically via a single nft -f - call.
	script := buildNFTScript(vpsIPs)
	nftCmd := exec.Command("nft", "-f", "-")
	nftCmd.Stdin = strings.NewReader(script)
	if out, err := nftCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("nft apply: %w — %s", err, out)
	}

	m.log.Printf("routing: TPROXY :%d ready, inet %s installed, vps_ips=%d",
		tproxyPort, nftTable, len(vpsIPs))
	return nil
}

// ── nftables ──────────────────────────────────────────────────────────────────

// buildNFTScript returns a complete nftables table definition for TPROXY.
//
// Two chains:
//   - MANGLE: inner chain; skips RFC1918, VPS IPs, ct reply; TPROXY TCP+UDP
//   - mangle_pre: prerouting hook -150; routes br-lan ingress into MANGLE
//
// Only LAN-forwarded traffic is TPROXY'd. Router's own traffic goes direct
// through the main routing table (NTP, DNS, system updates work normally).
// vpnd heartbeat bypasses nftables entirely via vpnbot_vps set (the API
// server IP is in route_exclude_address and therefore in vpnbot_vps).
func buildNFTScript(vpsIPs []string) string {
	var b strings.Builder

	fmt.Fprintf(&b, "table inet %s {\n", nftTable)

	// RFC1918 + non-routable ranges — never TPROXY these.
	b.WriteString("\tset vpnbot_lan {\n")
	b.WriteString("\t\ttype ipv4_addr\n")
	b.WriteString("\t\tflags interval\n")
	b.WriteString("\t\telements = {\n")
	b.WriteString("\t\t\t0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,\n")
	b.WriteString("\t\t\t169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16,\n")
	b.WriteString("\t\t\t224.0.0.0/4, 240.0.0.0/4\n")
	b.WriteString("\t\t}\n")
	b.WriteString("\t}\n")

	// VPN server IPs — bypass TPROXY to prevent routing loops.
	b.WriteString("\tset vpnbot_vps {\n")
	b.WriteString("\t\ttype ipv4_addr\n")
	b.WriteString("\t\tflags interval\n")
	if len(vpsIPs) > 0 {
		b.WriteString("\t\telements = { ")
		b.WriteString(strings.Join(vpsIPs, ", "))
		b.WriteString(" }\n")
	}
	b.WriteString("\t}\n")

	// Inner chain: TPROXY for br-lan forwarded traffic.
	b.WriteString("\tchain MANGLE {\n")
	b.WriteString("\t\tip daddr @vpnbot_lan return\n")
	b.WriteString("\t\tip daddr @vpnbot_vps return\n")
	b.WriteString("\t\tct direction reply return\n")
	fmt.Fprintf(&b, "\t\tip protocol tcp meta mark set %s tproxy ip to :%d accept\n", tproxyFwmark, tproxyPort)
	fmt.Fprintf(&b, "\t\tip protocol udp meta mark set %s tproxy ip to :%d accept\n", tproxyFwmark, tproxyPort)
	b.WriteString("\t}\n")

	// Hook: intercept LAN-forwarded traffic (br-lan ingress).
	b.WriteString("\tchain mangle_pre {\n")
	b.WriteString("\t\ttype filter hook prerouting priority -150; policy accept;\n")
	b.WriteString("\t\tiifname \"br-lan\" jump MANGLE\n")
	b.WriteString("\t}\n")

	b.WriteString("}\n")
	return b.String()
}

// updateVPSNftset replaces vpnbot_vps elements without a full routing restart.
// Called after successful hot reload when VPS IPs may have changed.
func (m *Manager) updateVPSNftset(vpsIPs []string) {
	exec.Command("nft", "flush", "set", "inet", nftTable, "vpnbot_vps").Run()
	if len(vpsIPs) > 0 {
		exec.Command("nft", "add", "element", "inet", nftTable, "vpnbot_vps",
			"{ "+strings.Join(vpsIPs, ", ")+" }").Run()
	}
}

// ── helpers ───────────────────────────────────────────────────────────────────

func saveVPSIPs(ips []string) error {
	if err := os.MkdirAll(filepath.Dir(vpsIPsPath), 0755); err != nil {
		return err
	}
	return os.WriteFile(vpsIPsPath, []byte(strings.Join(ips, "\n")), 0600)
}

func loadVPSIPs() []string {
	data, err := os.ReadFile(vpsIPsPath)
	if err != nil {
		return nil
	}
	var ips []string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			ips = append(ips, line)
		}
	}
	return ips
}

// isPrivateCIDR returns true for RFC1918 and other non-routable IP ranges.
// Used to filter route_exclude_address: only public IPs are VPS server addresses.
func isPrivateCIDR(s string) bool {
	var ip net.IP
	if strings.Contains(s, "/") {
		ip, _, _ = net.ParseCIDR(s)
	} else {
		ip = net.ParseIP(s)
	}
	if ip == nil {
		return false
	}
	for _, cidr := range []string{
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
		"127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10",
	} {
		_, network, _ := net.ParseCIDR(cidr)
		if network != nil && network.Contains(ip) {
			return true
		}
	}
	return false
}

// patchRouterConfig applies all router-specific patches to the sing-box config:
//   - Injects Clash API (external_controller at 127.0.0.1:9090)
//   - Replaces TUN inbound with TPROXY inbound (port 7893, UDP timeout 5m)
//   - Preserves route.default_mark=100 so sing-box outbound bypasses TPROXY
//   - Disables interrupt_exist_connections on selector/urltest outbounds
//
// Returns the patched JSON and VPS IPs from the original TUN route_exclude_address.
// These IPs populate the vpnbot_vps nftset to prevent routing loops.
func patchRouterConfig(data []byte) ([]byte, []string, error) {
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, nil, fmt.Errorf("invalid JSON: %w", err)
	}

	// Clash API.
	exp, _ := cfg["experimental"].(map[string]any)
	if exp == nil {
		exp = map[string]any{}
	}
	if _, exists := exp["clash_api"]; !exists {
		exp["clash_api"] = map[string]any{
			"external_controller": "127.0.0.1:9090",
			"secret":              "",
		}
	}
	cfg["experimental"] = exp

	// route.default_mark=100 (0x64): all sing-box outbound sockets bypass TPROXY.
	route, _ := cfg["route"].(map[string]any)
	if route == nil {
		route = map[string]any{}
	}
	route["default_mark"] = 100
	cfg["route"] = route

	// Replace TUN inbound with TPROXY inbound; extract VPS IPs before replacing.
	var vpsIPs []string
	if inbounds, ok := cfg["inbounds"].([]any); ok {
		patched := make([]any, 0, len(inbounds))
		for _, ib := range inbounds {
			ibMap, ok := ib.(map[string]any)
			if !ok || ibMap["type"] != "tun" {
				patched = append(patched, ib)
				continue
			}
			vpsIPs = extractVPSIPs(ibMap)
			patched = append(patched, map[string]any{
				"type":        "tproxy",
				"tag":         "tproxy-in",
				"listen":      "::",
				"listen_port": tproxyPort,
				"udp_timeout": "5m",
			})
		}
		cfg["inbounds"] = patched
	}

	// interrupt_exist_connections: false — prevents killing all LAN clients
	// when switching VPN servers via Clash API selector.
	if outbounds, ok := cfg["outbounds"].([]any); ok {
		for _, ob := range outbounds {
			obMap, ok := ob.(map[string]any)
			if !ok {
				continue
			}
			obType, _ := obMap["type"].(string)
			if obType == "selector" || obType == "urltest" {
				obMap["interrupt_exist_connections"] = false
			}
		}
	}

	patched, err := json.MarshalIndent(cfg, "", "  ")
	return patched, vpsIPs, err
}

// extractVPSIPs reads route_exclude_address from a TUN inbound config and
// returns public IPv4 CIDRs. These are VPN server IPs that must bypass TPROXY
// to prevent routing loops. IPv6 and private ranges are excluded because
// vpnbot_vps is type ipv4_addr and nftables can't put IPv6 in an IPv4 set.
func extractVPSIPs(tunInbound map[string]any) []string {
	excludeRaw, ok := tunInbound["route_exclude_address"]
	if !ok {
		return nil
	}
	excludeList, ok := excludeRaw.([]any)
	if !ok {
		return nil
	}
	var ips []string
	for _, v := range excludeList {
		s, ok := v.(string)
		if !ok || s == "" {
			continue
		}
		// Skip IPv6 — vpnbot_vps is type ipv4_addr, nftables rejects IPv6 CIDRs.
		if strings.Contains(s, ":") {
			continue
		}
		if !isPrivateCIDR(s) {
			ips = append(ips, s)
		}
	}
	return ips
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
