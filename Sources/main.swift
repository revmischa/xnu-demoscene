import AppKit
import MetalKit

let windowed = CommandLine.arguments.contains("--windowed")

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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
