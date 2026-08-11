//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

const (
	wmDestroy       = 0x0002
	wmCommand       = 0x0111
	wmUser          = 0x0400
	wmLeftButtonUp  = 0x0202
	wmLeftButtonDbl = 0x0203
	wmRightButtonUp = 0x0205

	nimAdd        = 0x00000000
	nimModify     = 0x00000001
	nimDelete     = 0x00000002
	nimSetVersion = 0x00000004

	notifyIconVersion4 = 4
	nifMessage         = 0x00000001
	nifIcon            = 0x00000002
	nifTip             = 0x00000004

	imageIcon      = 1
	lrLoadFromFile = 0x0010

	mfString    = 0x00000000
	mfSeparator = 0x00000800

	tpmRightButton = 0x0002
	tpmBottomAlign = 0x0020
	swShowNormal   = 1

	idOpenCenter = 1001
	idOpenOps    = 1002
	idPair       = 1003
	idExit       = 1004

	ninSelect    = wmUser + 0
	ninKeySelect = wmUser + 1
	trayMessage  = wmUser + 17

	createNoWindow = 0x08000000
)

type point struct {
	X int32
	Y int32
}

type msg struct {
	Hwnd     uintptr
	Message  uint32
	WParam   uintptr
	LParam   uintptr
	Time     uint32
	Pt       point
	LPrivate uint32
}

type wndClassEx struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     uintptr
	HIcon         uintptr
	HCursor       uintptr
	HbrBackground uintptr
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       uintptr
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

type windowsSettings struct {
	LockOnTrustLoss bool `json:"lock_on_trust_loss"`
}

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	registerClassEx       = user32.NewProc("RegisterClassExW")
	registerWindowMessage = user32.NewProc("RegisterWindowMessageW")
	createWindowEx        = user32.NewProc("CreateWindowExW")
	defWindowProc         = user32.NewProc("DefWindowProcW")
	getMessage            = user32.NewProc("GetMessageW")
	translateMessage      = user32.NewProc("TranslateMessage")
	dispatchMessage       = user32.NewProc("DispatchMessageW")
	postQuitMessage       = user32.NewProc("PostQuitMessage")
	shellNotifyIcon       = shell32.NewProc("Shell_NotifyIconW")
	loadImage             = user32.NewProc("LoadImageW")
	createPopupMenu       = user32.NewProc("CreatePopupMenu")
	appendMenu            = user32.NewProc("AppendMenuW")
	trackPopupMenu        = user32.NewProc("TrackPopupMenu")
	destroyMenu           = user32.NewProc("DestroyMenu")
	shellExecute          = shell32.NewProc("ShellExecuteW")
	getCursorPos          = user32.NewProc("GetCursorPos")
	setForegroundWindow   = user32.NewProc("SetForegroundWindow")
	messageBox            = user32.NewProc("MessageBoxW")
	lockWorkStation       = user32.NewProc("LockWorkStation")
	getModuleHandle       = kernel32.NewProc("GetModuleHandleW")
	createMutex           = kernel32.NewProc("CreateMutexW")
	closeHandle           = kernel32.NewProc("CloseHandle")

	hwnd           uintptr
	nid            notifyIconData
	pairScript     string
	statePath      string
	settingsPath   string
	trustCenterExe string
	taskbarCreated uint32
)

func main() {
	mutexName := utf16(`Local\ZorinTrustTray-v0.9.1`)
	mutex, _, mutexErr := createMutex.Call(
		0,
		0,
		uintptr(unsafe.Pointer(mutexName)),
	)
	if mutex == 0 {
		return
	}
	if mutexErr == syscall.Errno(183) {
		closeHandle.Call(mutex)
		return
	}
	defer closeHandle.Call(mutex)

	executable, err := os.Executable()
	if err != nil {
		return
	}
	uiDir := filepath.Dir(executable)
	pairScript = filepath.Join(uiDir, "pair-phone.bat")
	trustCenterExe = filepath.Join(uiDir, "ZorinTrustCenter.exe")

	if appData := os.Getenv("APPDATA"); appData != "" {
		stateDir := filepath.Join(appData, "ZorinTrust")
		statePath = filepath.Join(stateDir, "ui-state.json")
		settingsPath = filepath.Join(stateDir, "windows-settings.json")
	}

	if result, _, _ := registerWindowMessage.Call(
		uintptr(unsafe.Pointer(utf16("TaskbarCreated"))),
	); result != 0 {
		taskbarCreated = uint32(result)
	}

	if !createMessageWindow() {
		return
	}
	if !loadTrayIcon(uiDir) {
		return
	}

	// На логоне bootstrap может стартовать раньше Explorer. Не завершаем tray
	// из-за первой неудачи, а даём notification area спокойно появиться.
	deadline := time.Now().Add(60 * time.Second)
	for !addTrayIcon() {
		if time.Now().After(deadline) {
			trayLogf("notification area not ready after 60s")
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	trayLogf("tray icon ready")

	go statusLoop()
	messageLoop()
}

func createMessageWindow() bool {
	className := utf16("ZorinTrustTrayWindow")
	instance, _, _ := getModuleHandle.Call(0)

	class := wndClassEx{
		CbSize:        uint32(unsafe.Sizeof(wndClassEx{})),
		LpfnWndProc:   syscall.NewCallback(windowProc),
		HInstance:     instance,
		LpszClassName: className,
	}
	if result, _, err := registerClassEx.Call(
		uintptr(unsafe.Pointer(&class)),
	); result == 0 {
		trayLogf("register class failed: %v", err)
		return false
	}

	var createErr error
	hwnd, _, createErr = createWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(utf16("Zorin Trust Tray"))),
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		instance,
		0,
	)
	if hwnd == 0 {
		trayLogf("create window failed: %v", createErr)
		return false
	}

	return true
}

func loadTrayIcon(uiDir string) bool {
	iconPath := filepath.Join(uiDir, "zorin-trust.ico")
	icon, _, _ := loadImage.Call(
		0,
		uintptr(unsafe.Pointer(utf16(iconPath))),
		imageIcon,
		0,
		0,
		lrLoadFromFile,
	)

	nid = notifyIconData{
		CbSize:           uint32(unsafe.Sizeof(notifyIconData{})),
		HWnd:             hwnd,
		UID:              1,
		UFlags:           nifMessage | nifIcon | nifTip,
		UCallbackMessage: trayMessage,
		HIcon:            icon,
	}
	copyTip(nid.SzTip[:], tooltip(readUIState()))
	return true
}

func messageLoop() {
	var message msg
	for {
		result, _, _ := getMessage.Call(
			uintptr(unsafe.Pointer(&message)),
			0,
			0,
			0,
		)
		if int32(result) <= 0 {
			return
		}
		translateMessage.Call(uintptr(unsafe.Pointer(&message)))
		dispatchMessage.Call(uintptr(unsafe.Pointer(&message)))
	}
}

func statusLoop() {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	previousTrusted := false
	initialized := false
	var disconnectedSince time.Time

	for range ticker.C {
		state := readUIState()
		updateTip(state)

		if !initialized {
			previousTrusted = state.DeviceTrusted
			initialized = true
			continue
		}

		settings := readSettings()
		if !settings.LockOnTrustLoss {
			previousTrusted = state.DeviceTrusted
			disconnectedSince = time.Time{}
			continue
		}

		if state.DeviceTrusted {
			previousTrusted = true
			disconnectedSince = time.Time{}
			continue
		}

		if previousTrusted && disconnectedSince.IsZero() {
			disconnectedSince = time.Now()
		}

		// Короткий USB/ADB hiccup не должен мгновенно запирать рабочий стол.
		// Блокируем только если trust действительно отсутствует несколько секунд.
		if !disconnectedSince.IsZero() && time.Since(disconnectedSince) >= 3*time.Second {
			trayLogf("trusted phone lost; locking workstation")
			lockWorkStation.Call()
			previousTrusted = false
			disconnectedSince = time.Time{}
		}
	}
}

func readUIState() uiState {
	var state uiState
	if statePath == "" {
		return state
	}

	raw, err := os.ReadFile(statePath)
	if err != nil {
		return state
	}
	_ = json.Unmarshal(raw, &state)
	return state
}

func readSettings() windowsSettings {
	var settings windowsSettings
	if settingsPath == "" {
		return settings
	}

	raw, err := os.ReadFile(settingsPath)
	if err != nil {
		return settings
	}
	_ = json.Unmarshal(raw, &settings)
	return settings
}

func windowProc(
	handle uintptr,
	message uint32,
	wParam uintptr,
	lParam uintptr,
) uintptr {
	if taskbarCreated != 0 && message == taskbarCreated {
		addTrayIcon()
		return 0
	}

	switch message {
	case trayMessage:
		// В NOTIFYICON_VERSION_4 событие находится в LOWORD(lParam), а id
		// иконки — в HIWORD. Сравнивать весь lParam нельзя.
		event := uint32(lParam & 0xffff)
		switch event {
		case wmLeftButtonUp, wmLeftButtonDbl, ninSelect, ninKeySelect:
			openTrustCenter()
			return 0
		case wmRightButtonUp:
			showMenu()
			return 0
		}

	case wmCommand:
		switch int(wParam & 0xffff) {
		case idOpenCenter:
			openTrustCenter()
		case idOpenOps:
			go openOps()
		case idPair:
			openPair()
		case idExit:
			shellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
			postQuitMessage.Call(0)
		}
		return 0

	case wmDestroy:
		shellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
		postQuitMessage.Call(0)
		return 0
	}

	result, _, _ := defWindowProc.Call(handle, uintptr(message), wParam, lParam)
	return result
}

func showMenu() {
	menu, _, _ := createPopupMenu.Call()
	if menu == 0 {
		return
	}
	defer destroyMenu.Call(menu)

	appendMenu.Call(
		menu,
		mfString,
		idOpenCenter,
		uintptr(unsafe.Pointer(utf16("Open Trust Center"))),
	)
	appendMenu.Call(
		menu,
		mfString,
		idOpenOps,
		uintptr(unsafe.Pointer(utf16("Open Zorin Ops"))),
	)
	appendMenu.Call(menu, mfSeparator, 0, 0)
	appendMenu.Call(
		menu,
		mfString,
		idPair,
		uintptr(unsafe.Pointer(utf16("Pair phone"))),
	)
	appendMenu.Call(menu, mfSeparator, 0, 0)
	appendMenu.Call(
		menu,
		mfString,
		idExit,
		uintptr(unsafe.Pointer(utf16("Exit tray"))),
	)

	var cursor point
	getCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
	setForegroundWindow.Call(hwnd)
	trackPopupMenu.Call(
		menu,
		tpmRightButton|tpmBottomAlign,
		uintptr(cursor.X),
		uintptr(cursor.Y),
		0,
		hwnd,
		0,
	)
}

func addTrayIcon() bool {
	result, _, _ := shellNotifyIcon.Call(
		nimAdd,
		uintptr(unsafe.Pointer(&nid)),
	)
	if result == 0 {
		return false
	}

	nid.UVersion = notifyIconVersion4
	shellNotifyIcon.Call(nimSetVersion, uintptr(unsafe.Pointer(&nid)))
	return true
}

func tooltip(state uiState) string {
	if state.DeviceTrusted && state.OwnerPresent {
		return "Zorin Trust — Owner verified"
	}
	if state.DeviceTrusted {
		return "Zorin Trust — Device trusted, phone locked"
	}
	if state.Transport != "" && state.Transport != "Offline" {
		return "Zorin Trust — Connecting"
	}
	return "Zorin Trust — Phone disconnected"
}

func updateTip(state uiState) {
	copyTip(nid.SzTip[:], tooltip(state))
	shellNotifyIcon.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

func openTrustCenter() {
	if _, err := os.Stat(trustCenterExe); err != nil {
		showError("ZorinTrustCenter.exe is missing from the installed UI directory.")
		return
	}

	command := exec.Command(trustCenterExe)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := command.Start(); err != nil {
		showError(err.Error())
	}
}

func openPair() {
	if pairScript == "" {
		return
	}

	command := exec.Command("cmd.exe", "/C", "start", "", pairScript)
	_ = command.Start()
}

func openOps() {
	if !opsHealthy() {
		startOpsHidden()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			time.Sleep(125 * time.Millisecond)
			if opsHealthy() {
				break
			}
		}
	}

	if !opsHealthy() {
		showError(
			"Zorin Ops is not responding on 127.0.0.1:47474.\n\n" +
				"Check %LOCALAPPDATA%\\ZorinTrust\\logs\\ops.log or run the startup doctor.",
		)
		return
	}

	verb := utf16("open")
	url := utf16("http://127.0.0.1:47474/")
	shellExecute.Call(
		0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(url)),
		0,
		0,
		swShowNormal,
	)
}

func opsHealthy() bool {
	client := &http.Client{
		Timeout: 350 * time.Millisecond,
	}
	response, err := client.Get("http://127.0.0.1:47474/api/state")
	if err != nil {
		return false
	}
	defer response.Body.Close()

	return response.StatusCode >= 200 && response.StatusCode < 500
}

func startOpsHidden() {
	executable, err := os.Executable()
	if err != nil {
		return
	}

	opsPath := filepath.Join(
		filepath.Dir(filepath.Dir(executable)),
		"bin",
		"zorin-ops.exe",
	)
	if _, err := os.Stat(opsPath); err != nil {
		return
	}

	command := exec.Command(opsPath)
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
	_ = command.Start()
}

func showError(text string) {
	messageBox.Call(
		0,
		uintptr(unsafe.Pointer(utf16(text))),
		uintptr(unsafe.Pointer(utf16("Zorin Trust"))),
		0x10,
	)
}

func trayLogf(format string, args ...any) {
	fmt.Fprintf(
		os.Stderr,
		time.Now().Format(time.RFC3339)+" "+format+"\n",
		args...,
	)
}

func utf16(value string) *uint16 {
	pointer, _ := syscall.UTF16PtrFromString(value)
	return pointer
}

func copyTip(destination []uint16, value string) {
	encoded := syscall.StringToUTF16(value)
	if len(encoded) > len(destination) {
		encoded = encoded[:len(destination)]
	}
	copy(destination, encoded)
}
