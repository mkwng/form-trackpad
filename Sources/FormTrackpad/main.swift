import AppKit

// If the app is stopped or crashes while the pad is in multi-touch mode, the pad would stay silent
// until the keyboard is replugged. So on every way out, hand it back to macOS first.
private func restoreAndReraise(_ signalNumber: Int32) {
    AppDelegate.shared?.restorePad()
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

for crash in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
    signal(crash, restoreAndReraise)
}

private var quitSources: [DispatchSourceSignal] = []
for quit in [SIGTERM, SIGINT, SIGHUP] {
    signal(quit, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: quit, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    quitSources.append(source)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
