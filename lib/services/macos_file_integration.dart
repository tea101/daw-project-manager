import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Neyrinck PT Peek's bundle identifier (read from its installed
/// Info.plist, version 1.4.4): used only to tell whether it is installed,
/// so Quick Look — which shows PT Peek's preview — is offered for `.ptx`.
const String kPtPeekBundleId = 'com.neyrinck.ptpeek';

/// Pro Tools session extensions PT Peek opens (version 10 and later).
const Set<String> kPtPeekSessionExtensions = {'.ptx'};

/// Whether PT Peek is worth offering for [path]: a Pro Tools 10+ session.
bool ptPeekHandles(String path) =>
    kPtPeekSessionExtensions.contains(p.extension(path).toLowerCase());

/// macOS file integration through the app's own native code
/// (`FileIntegrationBridge` in macos/Runner/MainFlutterWindow.swift):
/// Quick Look in the system's own panel, whether an app is installed, and
/// handing a file to a named app (external players, v3.0.6).
/// Every call answers false/null off macOS and never throws.
class MacFileIntegration {
  MacFileIntegration._();

  static const _channel =
      MethodChannel('com.bandpassrecords.dpm/file_integration');

  static bool get supported => !kIsWeb && Platform.isMacOS;

  /// Whether an app with [bundleId] is installed (Launch Services knows it).
  static Future<bool> appInstalled(String bundleId) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'appInstalled', {'bundleId': bundleId}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Asks macOS to open [path] in the app with [bundleId] — what Finder's
  /// Open With does. False when the app isn't installed or macOS refused;
  /// true says only that macOS handed the file over (whether the app then
  /// loads it is up to the app). Nothing is changed in the file.
  static Future<bool> openWith(String bundleId, String path) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'openWith', {'bundleId': bundleId, 'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Shows [paths] in the system Quick Look panel — the same preview as
  /// pressing Space in Finder, from whichever app provides it (PT Peek for
  /// a `.ptx`). False when nothing could be shown.
  static Future<bool> quickLook(List<String> paths) async {
    if (!supported || paths.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('quickLook', {'paths': paths}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
