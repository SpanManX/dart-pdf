import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.milanko.dartpdf/image_clipboard');

/// Native [copyPngToClipboard]: hands the PNG [bytes] to the host app, which
/// writes it to the OS clipboard. Returns true once the write completes;
/// [clipboardSnapshotHandler] turns a thrown error (an unsupported platform /
/// missing native binding) into a false result.
Future<bool> copyPngToClipboard(Uint8List bytes) async {
  return await _channel.invokeMethod<bool>('copyPng', bytes) ?? false;
}
