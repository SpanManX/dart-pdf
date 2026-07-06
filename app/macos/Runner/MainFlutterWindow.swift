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
          if let payload = appDelegate.pendingFiles.first {
            appDelegate.pendingFiles.removeFirst()
            result(payload)
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
      if call.method == "readImage" {
        result(self.readImageFromClipboard())
        return
      }
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

  private func readImageFromClipboard() -> FlutterStandardTypedData? {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: .png) {
      return FlutterStandardTypedData(bytes: data)
    }
    if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
      return FlutterStandardTypedData(bytes: data)
    }
    if let data = pasteboard.data(forType: .tiff),
       let converted = pngData(fromTiff: data) {
      return FlutterStandardTypedData(bytes: converted)
    }
    if let image = NSImage(pasteboard: pasteboard),
       let tiff = image.tiffRepresentation,
       let converted = pngData(fromTiff: tiff) {
      return FlutterStandardTypedData(bytes: converted)
    }
    return nil
  }

  private func pngData(fromTiff data: Data) -> Data? {
    guard let bitmap = NSBitmapImageRep(data: data) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }
}
