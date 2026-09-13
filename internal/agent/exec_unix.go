//go:build !windows

package agent

import "syscall"

// syscallExec replaces the current process image in place (same PID), which
// is what lets OTA self-restart into the freshly installed binary without
// depending on any external supervisor — Keenetic's S99vpnd launches vpnd as
// a bare background job with no respawn at all (unlike OpenWrt's procd).
func syscallExec(path string, argv, envv []string) error {
	return syscall.Exec(path, argv, envv)
}
