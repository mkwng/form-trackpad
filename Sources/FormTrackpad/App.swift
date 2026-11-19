import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import TouchCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private let device = TouchpadDevice()
    private let engine = GestureEngine()
    private lazy var synth = EventSynth()
    private var deadline: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var running = false

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        UserDefaults.standard.register(defaults: ["pointerSpeed": 1.0, "scrollSpeed": 1.0])
        engine.tuning.pointerSpeed = UserDefaults.standard.double(forKey: "pointerSpeed")
        engine.tuning.scrollSpeed = UserDefaults.standard.double(forKey: "scrollSpeed")
        engine.secondsSinceKeystroke = {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        }
        buildMenu()

        device.onFrame = { [weak self] frame in self?.handle(frame) }
        device.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            if !connected { self.engine.reset().forEach(self.synth.perform) }
            self.refreshStatus()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.device.reassertTouchpadMode()
        }

        if SMAppService.mainApp.status == .notRegistered, !UserDefaults.standard.bool(forKey: "loginChoiceMade") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginChoiceMade")
        }

        // Without permission to post events the pad would go silent, so it stays a plain mouse
        // until permission is there.
        if AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            startDriving()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                if AXIsProcessTrusted() { self?.startDriving() }
            }
        }
        refreshStatus()
    }

    private func startDriving() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard !running else { return }
        running = true
        Log.write("Started")
        device.start()
        refreshStatus()
    }

    /// Puts the pad back the way macOS found it. Safe to call more than once.
    func restorePad() {
        device.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.reset().forEach(synth.perform)
        restorePad()
        Log.write("Quit")
    }

    /// Opening the app again while it runs shows the menu, so it can be reached from the keyboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    // MARK: Input

    private func handle(_ frame: Frame) {
        if !frame.contacts.isEmpty { declareActivity() }
        engine.process(frame).forEach(synth.perform)
        scheduleDeadline()
    }

    /// The engine has a couple of things that happen on a clock (starting a drag, letting go).
    private func scheduleDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let due = engine.nextDeadline else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.engine.advance(to: ProcessInfo.processInfo.systemUptime).forEach(self.synth.perform)
            self.scheduleDeadline()
        }
        deadline = item
        let wait = max(0, due - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private var lastActivity = 0.0
    private var activityAssertion: IOPMAssertionID = 0

    /// Touching the pad should wake the display and hold off sleep, as any pointing device does.
    private func declareActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActivity > 5 else { return }
        lastActivity = now
        IOPMAssertionDeclareUserActivity("Form touchpad in use" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.and.hand.point.up.left", accessibilityDescription: "Form Trackpad")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusLine)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(sliderItem(title: "Tracking Speed", key: "pointerSpeed") { [weak self] in self?.engine.tuning.pointerSpeed = $0 })
        menu.addItem(sliderItem(title: "Scrolling Speed", key: "scrollSpeed") { [weak self] in self?.engine.tuning.scrollSpeed = $0 })
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Form Trackpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatus()
    }

    private func refreshStatus() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            statusLine.title = "Form Trackpad needs Accessibility permission"
        } else if device.accessDenied {
            statusLine.title = "Form Trackpad needs Input Monitoring permission"
        } else {
            statusLine.title = device.isConnected ? "Form is connected" : "Form is not connected"
        }
        permissionItem.isHidden = trusted
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        refreshStatus()
    }

    private var sliderHandlers: [ObjectIdentifier: (key: String, apply: (Double) -> Void)] = [:]

    /// A labelled slider row. Speeds run from 0.4× to 2.5×, with 1× in the middle.
    private func sliderItem(title: String, key: String, apply: @escaping (Double) -> Void) -> NSMenuItem {
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        let position = log(UserDefaults.standard.double(forKey: key)) / log(2.5)
        let slider = NSSlider(value: position, minValue: -1, maxValue: 1, target: self, action: #selector(sliderMoved(_:)))
        slider.controlSize = .small
        sliderHandlers[ObjectIdentifier(slider)] = (key, apply)

        let stack = NSStackView(views: [label, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            slider.widthAnchor.constraint(equalToConstant: 212),
        ])
        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let handler = sliderHandlers[ObjectIdentifier(sender)] else { return }
        let value = pow(2.5, sender.doubleValue)
        UserDefaults.standard.set(value, forKey: handler.key)
        handler.apply(value)
    }
}
