import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Neyrinck PT Peek's bundle identifier (read from its installed
/// Info.plist, version 1.4.4). PT Peek has no command line, scripting or
/// export: DAW Project Manager only asks macOS to open a session in it, the
/// way Finder's Open With does.
const String kPtPeekBundleId = 'com.neyrinck.ptpeek';

/// Pro Tools session extensions PT Peek opens (version 10 and later).
const Set<String> kPtPeekSessionExtensions = {'.ptx'};

/// Whether PT Peek is worth offering for [path]: a Pro Tools 10+ session.
bool ptPeekHandles(String path) =>
    kPtPeekSessionExtensions.contains(p.extension(path).toLowerCase());

/// macOS file integration through the app's own native code
/// (`FileIntegrationBridge` in macos/Runner/MainFlutterWindow.swift):
/// Quick Look in the system's own panel, and opening a file in a named app.
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

  /// Opens [path] in the app with [bundleId]. False when the app isn't
  /// installed or macOS refused. Nothing is changed in the file or the app.
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
