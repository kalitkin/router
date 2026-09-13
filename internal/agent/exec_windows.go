//go:build windows

package agent

import "errors"

// vpnd only ever runs on the router (Linux); this stub exists solely so the
// package still builds on a Windows dev machine.
func syscallExec(path string, argv, envv []string) error {
	return errors.New("self re-exec not supported on windows")
}
