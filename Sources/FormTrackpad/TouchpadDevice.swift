import Foundation
import IOKit.hid
import TouchCore

/// Finds the Form's touchpad, switches it into multi-touch reporting, and delivers finger frames.
///
/// Out of the box the pad runs in "mouse mode" and only sends pointer, scroll and tap. Writing 3 to
/// its Input Mode feature (the same thing Windows does for Precision Touchpads) makes it report
/// every finger instead. Writing 0 puts it back.
final class TouchpadDevice {
    static let vendorID = 0x29ea
    static let productID = 0x1000

    private enum InputMode: UInt8 { case mouse = 0, touchpad = 3 }
    private static let inputModeReportID: CFIndex = 6

    var onFrame: ((Frame) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var isConnected = false
    /// macOS refused to let the app read the pad (Input Monitoring is switched off for it).
    private(set) var accessDenied = false

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    func start() {
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: kHIDPage_Digitizer,
            kIOHIDPrimaryUsageKey: kHIDUsage_Dig_TouchPad,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<TouchpadDevice>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<TouchpadDevice>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { Log.write("Could not open the HID manager: \(String(result, radix: 16))") }
    }

    /// Hands the pad back to macOS as a plain mouse.
    func stop() {
        setMode(.mouse)
    }

    /// The pad forgets its mode when it loses power, so this is called again after sleep.
    func reassertTouchpadMode() {
        setMode(.touchpad)
    }

    private func attach(_ newDevice: IOHIDDevice) {
        let opened = IOHIDDeviceOpen(newDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        accessDenied = opened == kIOReturnNotPermitted
        if opened != kIOReturnSuccess {
            Log.write("Could not open the touchpad: \(String(opened, radix: 16))")
            if accessDenied { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
            onConnectionChange?(false)
            return
        }
        device = newDevice
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(newDevice, buffer, 64, { context, _, _, _, _, report, length in
            Unmanaged<TouchpadDevice>.fromOpaque(context!).takeUnretainedValue().receive(report, length)
        }, context)
        setMode(.touchpad)
        isConnected = true
        Log.write("Touchpad connected")
        onConnectionChange?(true)
    }

    private func detach(_ oldDevice: IOHIDDevice) {
        guard oldDevice == device else { return }
        device = nil
        isConnected = false
        Log.write("Touchpad disconnected")
        onConnectionChange?(false)
    }

    private func setMode(_ mode: InputMode) {
        guard let device else { return }
        var report: [UInt8] = [UInt8(Self.inputModeReportID), mode.rawValue]
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, Self.inputModeReportID, &report, report.count)
        if result != kIOReturnSuccess {
            Log.write("Could not set input mode \(mode): \(String(result, radix: 16))")
        }
    }

    private func receive(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        if Log.frames { Log.write("report " + bytes.map { String(format: "%02x", $0) }.joined()) }
        guard let parsed = FormReport.parse(bytes) else { return }
        onFrame?(Frame(time: ProcessInfo.processInfo.systemUptime, contacts: parsed.contacts, buttons: parsed.buttons))
    }
}
