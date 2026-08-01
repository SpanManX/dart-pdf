import 'dart:io';

/// Flatpak sets FLATPAK_ID for every sandboxed process. Those installations
/// update through the signed Flatpak remote, so the app must not advertise a
/// parallel AppImage download from GitHub.
bool get defaultStoreManagedUpdateChannel =>
    Platform.environment['FLATPAK_ID']?.isNotEmpty ?? false;
