//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

const (
	WM_DESTROY       = 0x0002
	WM_COMMAND       = 0x0111
	WM_USER          = 0x0400
	WM_LBUTTONUP     = 0x0202
	WM_LBUTTONDBLCLK = 0x0203
	WM_RBUTTONUP     = 0x0205
	NIM_ADD          = 0x00000000
	NIM_MODIFY       = 0x00000001
	NIM_DELETE       = 0x00000002
	NIF_MESSAGE      = 0x00000001
	NIF_ICON         = 0x00000002
	NIF_TIP          = 0x00000004
	IMAGE_ICON       = 1
	LR_LOADFROMFILE  = 0x0010
	MF_STRING        = 0x00000000
	TPM_RIGHTBUTTON  = 0x0002
	TPM_BOTTOMALIGN  = 0x0020
	SW_SHOWNORMAL    = 1
	IDC_OPEN         = 1001
	IDC_PAIR         = 1002
	IDC_EXIT         = 1003
	trayMessage      = WM_USER + 17
)

type point struct{ X, Y int32 }
type msg struct {
	Hwnd           uintptr
	Message        uint32
	WParam, LParam uintptr
	Time           uint32
	Pt             point
	LPrivate       uint32
}
type wndClassEx struct {
	CbSize                 uint32
	Style                  uint32
	LpfnWndProc            uintptr
	CbClsExtra, CbWndExtra int32
	HInstance              uintptr
	HIcon                  uintptr
	HCursor                uintptr
	HbrBackground          uintptr
	LpszMenuName           *uint16
	LpszClassName          *uint16
	HIconSm                uintptr
}
type notifyIconData struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         [16]byte
	HBalloonIcon     uintptr
}
type uiState struct {
	DeviceTrusted bool   `json:"device_trusted"`
	OwnerPresent  bool   `json:"owner_present"`
	Transport     string `json:"transport"`
}

var (
	user32               = syscall.NewLazyDLL("user32.dll")
	shell32              = syscall.NewLazyDLL("shell32.dll")
	kernel32             = syscall.NewLazyDLL("kernel32.dll")
	pRegisterClassEx     = user32.NewProc("RegisterClassExW")
	pCreateWindowEx      = user32.NewProc("CreateWindowExW")
	pDefWindowProc       = user32.NewProc("DefWindowProcW")
	pGetMessage          = user32.NewProc("GetMessageW")
	pTranslateMessage    = user32.NewProc("TranslateMessage")
	pDispatchMessage     = user32.NewProc("DispatchMessageW")
	pPostQuitMessage     = user32.NewProc("PostQuitMessage")
	pShellNotifyIcon     = shell32.NewProc("Shell_NotifyIconW")
	pLoadImage           = user32.NewProc("LoadImageW")
	pCreatePopupMenu     = user32.NewProc("CreatePopupMenu")
	pAppendMenu          = user32.NewProc("AppendMenuW")
	pTrackPopupMenu      = user32.NewProc("TrackPopupMenu")
	pDestroyMenu         = user32.NewProc("DestroyMenu")
	pGetCursorPos        = user32.NewProc("GetCursorPos")
	pSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	pGetModuleHandle     = kernel32.NewProc("GetModuleHandleW")
)

var hwnd uintptr
var nid notifyIconData
var uiScript, pairScript, statePath string

func u16(s string) *uint16 { p, _ := syscall.UTF16PtrFromString(s); return p }
func copyTip(dst []uint16, s string) {
	x := syscall.StringToUTF16(s)
	if len(x) > len(dst) {
		x = x[:len(dst)]
	}
	copy(dst, x)
}

func openPowerShell(script string) {
	if script == "" {
		return
	}
	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: false}
	_ = cmd.Start()
}
func openPair() {
	if pairScript == "" {
		return
	}
	cmd := exec.Command("cmd.exe", "/C", "start", "", pairScript)
	_ = cmd.Start()
}

func wndProc(h uintptr, m uint32, w, l uintptr) uintptr {
	switch m {
	case trayMessage:
		switch uint32(l) {
		case WM_LBUTTONUP, WM_LBUTTONDBLCLK:
			openPowerShell(uiScript)
			return 0
		case WM_RBUTTONUP:
			showMenu()
			return 0
		}
	case WM_COMMAND:
		switch int(w & 0xffff) {
		case IDC_OPEN:
			openPowerShell(uiScript)
		case IDC_PAIR:
			openPair()
		case IDC_EXIT:
			pShellNotifyIcon.Call(NIM_DELETE, uintptr(unsafe.Pointer(&nid)))
			pPostQuitMessage.Call(0)
		}
		return 0
	case WM_DESTROY:
		pShellNotifyIcon.Call(NIM_DELETE, uintptr(unsafe.Pointer(&nid)))
		pPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := pDefWindowProc.Call(h, uintptr(m), w, l)
	return r
}

func showMenu() {
	menu, _, _ := pCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer pDestroyMenu.Call(menu)
	pAppendMenu.Call(menu, MF_STRING, IDC_OPEN, uintptr(unsafe.Pointer(u16("Open Zorin Trust"))))
	pAppendMenu.Call(menu, MF_STRING, IDC_PAIR, uintptr(unsafe.Pointer(u16("Pair phone"))))
	pAppendMenu.Call(menu, MF_STRING, IDC_EXIT, uintptr(unsafe.Pointer(u16("Exit tray"))))
	var pt point
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	pSetForegroundWindow.Call(hwnd)
	pTrackPopupMenu.Call(menu, TPM_RIGHTBUTTON|TPM_BOTTOMALIGN, uintptr(pt.X), uintptr(pt.Y), 0, hwnd, 0)
}

func tooltip() string {
	b, err := os.ReadFile(statePath)
	if err != nil {
		return "Zorin Trust — offline"
	}
	var s uiState
	if json.Unmarshal(b, &s) != nil {
		return "Zorin Trust"
	}
	if s.DeviceTrusted && s.OwnerPresent {
		return "Zorin Trust — Owner verified"
	}
	if s.DeviceTrusted {
		return "Zorin Trust — Device trusted, phone locked"
	}
	if s.Transport != "" && s.Transport != "Offline" {
		return "Zorin Trust — Connecting"
	}
	return "Zorin Trust — Phone disconnected"
}
func updateTip() {
	copyTip(nid.SzTip[:], tooltip())
	pShellNotifyIcon.Call(NIM_MODIFY, uintptr(unsafe.Pointer(&nid)))
}

func main() {
	exe, _ := os.Executable()
	dir := filepath.Dir(exe)
	uiScript = filepath.Join(dir, "trust-center.ps1")
	pairScript = filepath.Join(dir, "pair-phone.bat")
	if appdata := os.Getenv("APPDATA"); appdata != "" {
		statePath = filepath.Join(appdata, "ZorinTrust", "ui-state.json")
	}
	clsName := u16("ZorinTrustTrayWindow")
	inst, _, _ := pGetModuleHandle.Call(0)
	wc := wndClassEx{CbSize: uint32(unsafe.Sizeof(wndClassEx{})), LpfnWndProc: syscall.NewCallback(wndProc), HInstance: inst, LpszClassName: clsName}
	if r, _, e := pRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
		fmt.Fprintln(os.Stderr, "register class:", e)
		return
	}
	hwnd, _, _ = pCreateWindowEx.Call(0, uintptr(unsafe.Pointer(clsName)), uintptr(unsafe.Pointer(u16("Zorin Trust Tray"))), 0, 0, 0, 0, 0, 0, 0, inst, 0)
	if hwnd == 0 {
		return
	}
	iconPath := filepath.Join(dir, "zorin-trust.ico")
	hicon, _, _ := pLoadImage.Call(0, uintptr(unsafe.Pointer(u16(iconPath))), IMAGE_ICON, 0, 0, LR_LOADFROMFILE)
	nid = notifyIconData{CbSize: uint32(unsafe.Sizeof(notifyIconData{})), HWnd: hwnd, UID: 1, UFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP, UCallbackMessage: trayMessage, HIcon: hicon}
	copyTip(nid.SzTip[:], tooltip())
	if r, _, _ := pShellNotifyIcon.Call(NIM_ADD, uintptr(unsafe.Pointer(&nid))); r == 0 {
		return
	}
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for range t.C {
			updateTip()
		}
	}()
	var m msg
	for {
		r, _, _ := pGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		pDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
}
