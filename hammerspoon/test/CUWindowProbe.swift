import AppKit

final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }

        let area = screen.visibleFrame
        for index in 0..<3 {
            let frame = NSRect(
                x: area.minX + 100 + CGFloat(index) * 45,
                y: area.maxY - 190 - CGFloat(index) * 45,
                width: 460,
                height: 150
            )
            let window = ProbeWindow(
                contentRect: frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "CU Window Probe \(index + 1)"
            window.isReleasedWhenClosed = false
            window.level = .normal

            let label = NSTextField(labelWithString: "Disposable isolation test window \(index + 1)")
            label.frame = NSRect(x: 24, y: 55, width: 400, height: 28)
            window.contentView?.addSubview(label)

            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CUWindowProbeMain {
    static var retainedDelegate: ProbeAppDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ProbeAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
