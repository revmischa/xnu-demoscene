import AppKit
import MetalKit

let windowed = CommandLine.arguments.contains("--windowed")
/// Dev aid: `--at 90` starts the demo clock and the sequencer at 90 seconds.
let startAt: Double = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--at"), i + 1 < a.count { return Double(a[i + 1]) ?? 0 }
    return 0
}()
/// Dev aid: `--shot out.png` saves a frame 1.5 s after start and quits.
let shotPath: String? = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--shot"), i + 1 < a.count { return a[i + 1] }
    return nil
}()

final class DemoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: DemoWindow!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = windowed ? NSRect(x: 80, y: 80, width: 1280, height: 720) : screen.frame
        let style: NSWindow.StyleMask = windowed ? [.titled, .closable, .resizable] : [.borderless]
        window = DemoWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false, screen: screen)
        window.title = "xnu-demo"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        let view = MTKView(frame: frame, device: device)
        renderer = Renderer(view: view)
        window.contentView = view
        if !windowed {
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            window.setFrame(screen.frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSCursor.hide()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 || e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return e
        }
        SystemInfo.shared.start()
        Audio.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) { NSCursor.hide() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Dev aid: `--render-audio out.wav` renders the whole soundtrack offline and exits.
if let i = CommandLine.arguments.firstIndex(of: "--render-audio"), i + 1 < CommandLine.arguments.count {
    renderAudioFile(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
