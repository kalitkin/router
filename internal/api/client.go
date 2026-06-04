package api

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	defaultTimeout = 15 * time.Second
	maxBodyBytes   = 2 * 1024 * 1024 // 2 MB
)

type Client struct {
	baseURL    string
	token      string
	httpClient *http.Client
}

func NewClient(baseURL, token string) *Client {
	transport := &http.Transport{
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		MaxIdleConns:        4,
		IdleConnTimeout:     60 * time.Second,
		DisableCompression:  false,
	}
	return &Client{
		baseURL: baseURL,
		token:   token,
		httpClient: &http.Client{
			Timeout:   defaultTimeout,
			Transport: transport,
		},
	}
}

// ── Heartbeat ──────────────────────────────────────────────────────────────────

type HeartbeatReq struct {
	IP               string         `json:"ip,omitempty"`
	FirmwareVersion  string         `json:"firmware_version,omitempty"`
	CurrentServer    string         `json:"current_server,omitempty"`
	AvailableServers []string       `json:"available_servers,omitempty"`
	CommandResult    *CommandResult `json:"command_result,omitempty"`
	SingboxRSSKB     int64          `json:"singbox_rss_kb,omitempty"`
	ConntrackCount   int            `json:"conntrack_count,omitempty"`
	UptimeSec        int64          `json:"uptime_sec,omitempty"`
}

// CommandResult mirrors agent.CommandResult but lives here to avoid import cycle.
type CommandResult struct {
	ID      string            `json:"id"`
	Success bool              `json:"success"`
	Output  map[string]string `json:"output,omitempty"`
	Error   string            `json:"error,omitempty"`
}

// Command mirrors agent.Command.
type Command struct {
	ID        string            `json:"id"`
	Type      string            `json:"type"`
	Params    map[string]string `json:"params,omitempty"`
	ExpiresAt int64             `json:"expires_at,omitempty"`
}

type HeartbeatResp struct {
	Status          string   `json:"status"`
	RouterID        int      `json:"router_id"`
	Config          string   `json:"config,omitempty"`
	UpdateAvailable bool     `json:"update_available"`
	UpdateVersion   string   `json:"update_version,omitempty"`
	UpdateURL       string   `json:"update_url,omitempty"`
	Command         *Command `json:"command,omitempty"` // pending command from server
}

func (c *Client) Heartbeat(ctx context.Context, req HeartbeatReq) (*HeartbeatResp, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	httpResp, err := c.do(ctx, http.MethodPost, "/vpnapi/v1/router/heartbeat", body)
	if err != nil {
		return nil, err
	}
	defer httpResp.Body.Close()

	if httpResp.StatusCode == http.StatusForbidden {
		return nil, ErrDeviceDenied
	}
	if httpResp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("heartbeat: HTTP %d", httpResp.StatusCode)
	}

	var resp HeartbeatResp
	if err := readJSON(httpResp.Body, &resp); err != nil {
		return nil, fmt.Errorf("decode heartbeat: %w", err)
	}
	return &resp, nil
}

// ── Sing-box config ────────────────────────────────────────────────────────────

// GetSingBoxConfig fetches full sing-box JSON from a Marzban subscription URL.
// subLink is the base subscription URL (e.g. https://host/sub/TOKEN).
func (c *Client) GetSingBoxConfig(ctx context.Context, subLink string) ([]byte, error) {
	url := subLink + "/sing-box"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("User-Agent", "SFA/1.0 vpnd")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch sing-box config: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("sing-box config: HTTP %d", resp.StatusCode)
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if err != nil {
		return nil, fmt.Errorf("read sing-box config: %w", err)
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("sing-box config: empty response")
	}
	return data, nil
}

// ── helpers ────────────────────────────────────────────────────────────────────

var ErrDeviceDenied = fmt.Errorf("device denied by server")

func (c *Client) do(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	url := c.baseURL + path
	var bodyReader io.Reader
	if body != nil {
		bodyReader = bytes.NewReader(body)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	return c.httpClient.Do(req)
}

func readJSON(r io.Reader, v any) error {
	data, err := io.ReadAll(io.LimitReader(r, maxBodyBytes))
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}
