import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Wire the incoming-file channel to the Dart IncomingFileService.
    let channel = FlutterMethodChannel(
      name: "dev.milanko.dartpdf/incoming",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    if let appDelegate = NSApp.delegate as? AppDelegate {
      appDelegate.incomingChannel = channel
      channel.setMethodCallHandler { (call, result) in
        if call.method == "getInitialFile" {
          if let path = appDelegate.pendingFiles.first {
            appDelegate.pendingFiles.removeFirst()
            result(appDelegate.payload(for: path))
          } else {
            result(nil)
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    let imageClipboardChannel = FlutterMethodChannel(
      name: "dev.milanko.dartpdf/image_clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    imageClipboardChannel.setMethodCallHandler { (call, result) in
      guard call.method == "copyPng" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let typed = call.arguments as? FlutterStandardTypedData else {
        result(FlutterError(
          code: "bad_args",
          message: "copyPng expects PNG bytes",
          details: nil))
        return
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      result(pasteboard.setData(typed.data, forType: .png))
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
