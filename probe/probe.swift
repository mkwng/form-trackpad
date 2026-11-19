import Foundation
import IOKit.hid

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDVendorIDKey: 0x29ea, kIOHIDProductIDKey: 0x1000,
                            kIOHIDPrimaryUsagePageKey: 0x0d, kIOHIDPrimaryUsageKey: 0x05]
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("manager open:", String(openRes, radix: 16))
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else { print("no device"); exit(1) }
print("devices:", set.count)
func getFeature(_ id: Int, _ size: Int) {
    var buf = [UInt8](repeating: 0, count: size)
    var len = size
    let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, id, &buf, &len)
    print("feature \(id): res=\(String(r, radix: 16)) len=\(len) data=\(buf.prefix(min(len, 8)).map { String(format: "%02x", $0) }.joined(separator: " "))")
}
getFeature(4, 2); getFeature(6, 2); getFeature(7, 2)
if CommandLine.arguments.contains("--listen") {
    let secs = 6.0
    var mode: [UInt8] = [6, 3]
    print("set mode 3:", String(IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 6, &mode, 2), radix: 16))
    getFeature(6, 2)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var n = 0
    let cb: IOHIDReportCallback = { ctx, res, sender, type, id, report, len in
        let d = UnsafeBufferPointer(start: report, count: len).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("in id=\(id) len=\(len): \(d)")
    }
    IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, cb, nil)
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    CFRunLoopRunInMode(.defaultMode, secs, false)
    mode = [6, 0]
    print("restore mode 0:", String(IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 6, &mode, 2), radix: 16))
    getFeature(6, 2)
    _ = n; n += 1
}
