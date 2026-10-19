import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Default to a comfortable desktop size, centred on the main screen.
    let size = NSSize(width: 1360, height: 900)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
    self.setFrame(NSRect(origin: origin, size: size), display: true)
    self.minSize = NSSize(width: 1000, height: 680)
    self.title = "Localhost Recording Studio"
    self.setFrameAutosaveName("LocalhostStudioMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // Closing the only window quits the app. Going through terminate (like Cmd+Q) lets Flutter stop
  // the engine sidecar while the window still exists; a plain close left the app running windowless.
  override func performClose(_ sender: Any?) {
    NSApp.terminate(sender)
  }
}
