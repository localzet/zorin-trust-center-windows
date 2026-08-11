//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	version = "0.9.3"

	wmDestroy = 0x0002
	wmCommand = 0x0111
	wmTimer   = 0x0113

	wsOverlappedWindow = 0x00CF0000
	wsVisible          = 0x10000000
	wsChild            = 0x40000000
	wsTabStop          = 0x00010000

	bsPushButton   = 0x00000000
	bsAutoCheckbox = 0x00000003

	bmGetCheck = 0x00F0
	bmSetCheck = 0x00F1
	bstChecked = 1

	swShow        = 5
	swShownormal  = 1
	mbIconInfo    = 0x00000040
	mbIconError   = 0x00000010
	mbIconWarning = 0x00000030

	idOpenOps       = 1001
	idFreshApproval = 1002
	idLockNow       = 1003
	idPairPhone     = 1004
	idLockOnLoss    = 1005
	idClose         = 1006

	controlAddress = "127.0.0.1:47473"
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

type hostControlRequest struct {
	Token    string `json:"token"`
	Op       string `json:"op"`
	Action   string `json:"action,omitempty"`
	Resource string `json:"resource,omitempty"`
	Prompt   string `json:"prompt,omitempty"`
	Explicit bool   `json:"explicit,omitempty"`
}

type hostControlStatus struct {
	Trusted          bool   `json:"trusted"`
	OwnerPresent     bool   `json:"owner_present"`
	HostFingerprint  string `json:"host_fingerprint"`
	PhoneFingerprint string `json:"phone_fingerprint,omitempty"`
	IdentityProvider string `json:"identity_provider"`
}

type hostControlResponse struct {
	OK      bool               `json:"ok"`
	Allowed bool               `json:"allowed,omitempty"`
	Reason  string             `json:"reason,omitempty"`
	Status  *hostControlStatus `json:"status,omitempty"`
	Error   string             `json:"error,omitempty"`
}

type windowsSettings struct {
	LockOnTrustLoss bool `json:"lock_on_trust_loss"`
}

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	registerClassEx = user32.NewProc("RegisterClassExW")
	createWindowEx  = user32.NewProc("CreateWindowExW")
	defWindowProc   = user32.NewProc("DefWindowProcW")
	getMessage      = user32.NewProc("GetMessageW")
	translateMsg    = user32.NewProc("TranslateMessage")
	dispatchMsg     = user32.NewProc("DispatchMessageW")
	postQuitMessage = user32.NewProc("PostQuitMessage")
	setWindowText   = user32.NewProc("SetWindowTextW")
	showWindow      = user32.NewProc("ShowWindow")
	updateWindow    = user32.NewProc("UpdateWindow")
	messageBox      = user32.NewProc("MessageBoxW")
	sendMessage     = user32.NewProc("SendMessageW")
	setTimer        = user32.NewProc("SetTimer")
	killTimer       = user32.NewProc("KillTimer")
	lockWorkStation = user32.NewProc("LockWorkStation")

	shellExecute    = shell32.NewProc("ShellExecuteW")
	getModuleHandle = kernel32.NewProc("GetModuleHandleW")

	mainWindow uintptr
	statusText uintptr
	lockCheck  uintptr
	pairScript string
	settings   string
)

func main() {
	exe, err := os.Executable()
	if err != nil {
		return
	}

	uiDir := filepath.Dir(exe)
	pairScript = filepath.Join(uiDir, "pair-phone.bat")
	settings = settingsPath()

	instance, _, _ := getModuleHandle.Call(0)
	className := utf16("ZorinTrustCenterWindow")

	class := wndClassEx{
		CbSize:        uint32(unsafe.Sizeof(wndClassEx{})),
		LpfnWndProc:   syscall.NewCallback(windowProc),
		HInstance:     instance,
		HbrBackground: 6,
		LpszClassName: className,
	}

	if result, _, _ := registerClassEx.Call(uintptr(unsafe.Pointer(&class))); result == 0 {
		return
	}

	mainWindow, _, _ = createWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(utf16("Zorin Trust Center"))),
		wsOverlappedWindow|wsVisible,
		200,
		160,
		700,
		500,
		0,
		0,
		instance,
		0,
	)
	if mainWindow == 0 {
		return
	}

	createControls(instance)
	applySettingsToUI()
	refreshStatus()

	setTimer.Call(mainWindow, 1, 2000, 0)
	showWindow.Call(mainWindow, swShow)
	updateWindow.Call(mainWindow)

	var message msg
	for {
		result, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) <= 0 {
			break
		}
		translateMsg.Call(uintptr(unsafe.Pointer(&message)))
		dispatchMsg.Call(uintptr(unsafe.Pointer(&message)))
	}
}

func createControls(instance uintptr) {
	createStatic(
		instance,
		"Zorin Trust Center",
		24,
		20,
		620,
		28,
	)

	createStatic(
		instance,
		"Native owner-presence and operating-system trust controls",
		24,
		50,
		620,
		22,
	)

	statusText = createStatic(
		instance,
		"Loading trust state...",
		24,
		92,
		630,
		150,
	)

	lockCheck = createButton(
		instance,
		"Lock Windows when the trusted phone disconnects",
		idLockOnLoss,
		24,
		258,
		420,
		28,
		bsAutoCheckbox,
	)

	createButton(instance, "Open Zorin Ops", idOpenOps, 24, 320, 140, 34, bsPushButton)
	createButton(instance, "Fresh approval", idFreshApproval, 174, 320, 140, 34, bsPushButton)
	createButton(instance, "Lock now", idLockNow, 324, 320, 110, 34, bsPushButton)
	createButton(instance, "Pair phone", idPairPhone, 444, 320, 110, 34, bsPushButton)
	createButton(instance, "Close", idClose, 564, 320, 90, 34, bsPushButton)

	createStatic(
		instance,
		"Lock-on-loss is opt-in and uses a short debounce in the tray process.",
		24,
		382,
		630,
		22,
	)
}

func createStatic(
	instance uintptr,
	text string,
	x int,
	y int,
	width int,
	height int,
) uintptr {
	handle, _, _ := createWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(utf16("STATIC"))),
		uintptr(unsafe.Pointer(utf16(text))),
		wsChild|wsVisible,
		uintptr(x),
		uintptr(y),
		uintptr(width),
		uintptr(height),
		mainWindow,
		0,
		instance,
		0,
	)
	return handle
}

func createButton(
	instance uintptr,
	text string,
	id int,
	x int,
	y int,
	width int,
	height int,
	buttonStyle uintptr,
) uintptr {
	handle, _, _ := createWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(utf16("BUTTON"))),
		uintptr(unsafe.Pointer(utf16(text))),
		wsChild|wsVisible|wsTabStop|buttonStyle,
		uintptr(x),
		uintptr(y),
		uintptr(width),
		uintptr(height),
		mainWindow,
		uintptr(id),
		instance,
		0,
	)
	return handle
}

func windowProc(
	hwnd uintptr,
	message uint32,
	wParam uintptr,
	lParam uintptr,
) uintptr {
	switch message {
	case wmCommand:
		handleCommand(int(wParam & 0xffff))
		return 0
	case wmTimer:
		refreshStatus()
		return 0
	case wmDestroy:
		killTimer.Call(hwnd, 1)
		postQuitMessage.Call(0)
		return 0
	}

	result, _, _ := defWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
	return result
}

func handleCommand(id int) {
	switch id {
	case idOpenOps:
		openURL("http://127.0.0.1:47474/")
	case idFreshApproval:
		go requestFreshApproval()
	case idLockNow:
		lockWorkStation.Call()
	case idPairPhone:
		openPairing()
	case idLockOnLoss:
		saveSettingsFromUI()
	case idClose:
		postQuitMessage.Call(0)
	}
}

func refreshStatus() {
	response, err := requestHostAgent(hostControlRequest{Op: "status"}, 800*time.Millisecond)
	if err != nil {
		setControlText(statusText, "Host Agent: offline\r\n"+err.Error())
		return
	}

	status := response.Status
	if status == nil {
		setControlText(statusText, "Host Agent returned no detailed status.")
		return
	}

	device := "disconnected"
	if status.Trusted {
		device = "trusted"
	}

	owner := "absent / phone locked"
	if status.OwnerPresent {
		owner = "verified"
	}

	phone := status.PhoneFingerprint
	if phone == "" {
		phone = "—"
	}

	text := fmt.Sprintf(
		"Device: %s\r\nOwner: %s\r\nHost: %s\r\nIdentity: %s\r\nPhone: %s",
		device,
		owner,
		status.HostFingerprint,
		status.IdentityProvider,
		phone,
	)
	setControlText(statusText, text)
}

func requestFreshApproval() {
	response, err := requestHostAgent(
		hostControlRequest{
			Op:       "authorize",
			Action:   "os.windows.sensitive",
			Resource: "local:trust-center",
			Prompt:   "Подтвердить чувствительный режим Zorin Trust Center на Windows",
			Explicit: true,
		},
		70*time.Second,
	)
	if err != nil {
		showMessage("Fresh approval failed", err.Error(), mbIconError)
		return
	}
	if !response.Allowed {
		showMessage("Fresh approval denied", response.Reason, mbIconWarning)
		return
	}

	showMessage(
		"Owner approved",
		"Fresh phone approval received. The proof remains transaction-bound and short-lived.",
		mbIconInfo,
	)
}

func requestHostAgent(
	request hostControlRequest,
	timeout time.Duration,
) (hostControlResponse, error) {
	token, err := controlToken()
	if err != nil {
		return hostControlResponse{}, err
	}

	connection, err := net.DialTimeout("tcp", controlAddress, 500*time.Millisecond)
	if err != nil {
		return hostControlResponse{}, err
	}
	defer connection.Close()

	_ = connection.SetDeadline(time.Now().Add(timeout))
	request.Token = token

	if err := json.NewEncoder(connection).Encode(request); err != nil {
		return hostControlResponse{}, err
	}

	var response hostControlResponse
	if err := json.NewDecoder(connection).Decode(&response); err != nil {
		return hostControlResponse{}, err
	}
	if response.Error != "" {
		return response, fmt.Errorf("%s", response.Error)
	}
	return response, nil
}

func controlToken() (string, error) {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return "", fmt.Errorf("APPDATA is unavailable")
	}

	raw, err := os.ReadFile(filepath.Join(appData, "ZorinTrust", "control.token"))
	if err != nil {
		return "", err
	}

	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", fmt.Errorf("control.token is empty")
	}
	return token, nil
}

func settingsPath() string {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return ""
	}
	return filepath.Join(appData, "ZorinTrust", "windows-settings.json")
}

func loadSettings() windowsSettings {
	var result windowsSettings
	if settings == "" {
		return result
	}

	raw, err := os.ReadFile(settings)
	if err != nil {
		return result
	}
	_ = json.Unmarshal(raw, &result)
	return result
}

func saveSettingsFromUI() {
	if settings == "" {
		return
	}

	checked, _, _ := sendMessage.Call(lockCheck, bmGetCheck, 0, 0)
	value := windowsSettings{
		LockOnTrustLoss: checked == bstChecked,
	}

	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return
	}

	_ = os.MkdirAll(filepath.Dir(settings), 0700)
	_ = os.WriteFile(settings, raw, 0600)
}

func applySettingsToUI() {
	value := loadSettings()
	state := uintptr(0)
	if value.LockOnTrustLoss {
		state = bstChecked
	}
	sendMessage.Call(lockCheck, bmSetCheck, state, 0)
}

func openPairing() {
	if pairScript == "" {
		return
	}
	command := exec.Command("cmd.exe", "/C", "start", "", pairScript)
	_ = command.Start()
}

func openURL(url string) {
	verb := utf16("open")
	target := utf16(url)
	shellExecute.Call(
		0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(target)),
		0,
		0,
		swShownormal,
	)
}

func showMessage(title string, text string, flags uintptr) {
	messageBox.Call(
		mainWindow,
		uintptr(unsafe.Pointer(utf16(text))),
		uintptr(unsafe.Pointer(utf16(title))),
		flags,
	)
}

func setControlText(handle uintptr, text string) {
	setWindowText.Call(handle, uintptr(unsafe.Pointer(utf16(text))))
}

func utf16(value string) *uint16 {
	pointer, _ := syscall.UTF16PtrFromString(value)
	return pointer
}
