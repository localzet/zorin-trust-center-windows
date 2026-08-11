//go:build windows

package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const createNoWindow = 0x08000000

var (
	bootKernel32    = syscall.NewLazyDLL("kernel32.dll")
	bootCreateMutex = bootKernel32.NewProc("CreateMutexW")
	bootCloseHandle = bootKernel32.NewProc("CloseHandle")
	bootLogMu       sync.Mutex
	bootLogPath     string
)

type bootService struct {
	name string
	path string
	args []string
	port string
	log  string
}

func bootU16(s string) *uint16 { p, _ := syscall.UTF16PtrFromString(s); return p }

func bootLogf(format string, args ...any) {
	bootLogMu.Lock()
	defer bootLogMu.Unlock()
	if bootLogPath == "" {
		return
	}
	_ = rotateBootLog(bootLogPath, 2<<20)
	f, err := os.OpenFile(bootLogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = fmt.Fprintf(f, "%s "+format+"\n", append([]any{time.Now().Format(time.RFC3339)}, args...)...)
}

func rotateBootLog(path string, max int64) error {
	st, err := os.Stat(path)
	if err != nil || st.Size() <= max {
		return nil
	}
	_ = os.Remove(path + ".1")
	return os.Rename(path, path+".1")
}

func portAlive(addr string) bool {
	c, err := net.DialTimeout("tcp", addr, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

func childLog(path string) *os.File {
	_ = rotateBootLog(path, 4<<20)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return nil
	}
	return f
}

func startHidden(s bootService) (*exec.Cmd, *os.File, error) {
	cmd := exec.Command(s.path, s.args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	f := childLog(s.log)
	if f != nil {
		cmd.Stdout = f
		cmd.Stderr = f
	}
	if err := cmd.Start(); err != nil {
		if f != nil {
			_ = f.Close()
		}
		return nil, nil, err
	}
	bootLogf("started %s pid=%d", s.name, cmd.Process.Pid)
	return cmd, f, nil
}

func supervise(s bootService) {
	backoff := time.Second
	for {
		if portAlive(s.port) {
			time.Sleep(2 * time.Second)
			backoff = time.Second
			continue
		}
		cmd, logFile, err := startHidden(s)
		if err != nil {
			bootLogf("start %s failed: %v", s.name, err)
			time.Sleep(backoff)
			if backoff < 15*time.Second {
				backoff *= 2
			}
			continue
		}
		started := time.Now()
		err = cmd.Wait()
		if logFile != nil {
			_ = logFile.Close()
		}
		bootLogf("%s exited after %s: %v", s.name, time.Since(started).Round(time.Millisecond), err)
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		time.Sleep(backoff)
		if backoff < 15*time.Second {
			backoff *= 2
		}
	}
}

func superviseTray(path, logPath string) {
	backoff := time.Second
	for {
		cmd := exec.Command(path)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		f := childLog(logPath)
		if f != nil {
			cmd.Stdout = f
			cmd.Stderr = f
		}
		if err := cmd.Start(); err != nil {
			if f != nil {
				_ = f.Close()
			}
			bootLogf("tray start failed: %v", err)
			time.Sleep(backoff)
			if backoff < 15*time.Second {
				backoff *= 2
			}
			continue
		}
		bootLogf("started tray pid=%d", cmd.Process.Pid)
		started := time.Now()
		err := cmd.Wait()
		if f != nil {
			_ = f.Close()
		}
		bootLogf("tray exited after %s: %v", time.Since(started).Round(time.Millisecond), err)
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		time.Sleep(backoff)
		if backoff < 15*time.Second {
			backoff *= 2
		}
	}
}

func main() {
	adb := flag.String("adb", "", "adb executable path")
	flag.Parse()

	mutexName := bootU16(`Local\ZorinTrustBootstrap-v0.8.0`)
	hMutex, _, mutexErr := bootCreateMutex.Call(0, 0, uintptr(unsafe.Pointer(mutexName)))
	if hMutex == 0 {
		return
	}
	if mutexErr == syscall.Errno(183) { // ERROR_ALREADY_EXISTS
		bootCloseHandle.Call(hMutex)
		return
	}
	defer bootCloseHandle.Call(hMutex)

	exe, err := os.Executable()
	if err != nil {
		return
	}
	uiDir := filepath.Dir(exe)
	root := filepath.Dir(uiDir)
	binDir := filepath.Join(root, "bin")
	logDir := filepath.Join(root, "logs")
	if os.MkdirAll(logDir, 0700) != nil {
		return
	}
	bootLogPath = filepath.Join(logDir, "bootstrap.log")
	bootLogf("bootstrap 0.8.0 starting")

	agentArgs := []string{"daemon"}
	if *adb != "" {
		agentArgs = append(agentArgs, "--adb", *adb)
	}
	services := []bootService{
		{name: "host-agent", path: filepath.Join(binDir, "zorin-host-agent.exe"), args: agentArgs, port: "127.0.0.1:47472", log: filepath.Join(logDir, "host-agent.log")},
		{name: "ops", path: filepath.Join(binDir, "zorin-ops.exe"), port: "127.0.0.1:47474", log: filepath.Join(logDir, "ops.log")},
		{name: "authority", path: filepath.Join(binDir, "zorin-authority.exe"), args: []string{"serve"}, port: "127.0.0.1:47475", log: filepath.Join(logDir, "authority.log")},
	}
	for _, s := range services {
		if _, err := os.Stat(s.path); err != nil {
			bootLogf("missing %s binary: %s", s.name, s.path)
			continue
		}
		go supervise(s)
	}

	tray := filepath.Join(uiDir, "ZorinTrustTray.exe")
	if _, err := os.Stat(tray); err == nil {
		go superviseTray(tray, filepath.Join(logDir, "tray.log"))
	}

	select {}
}
