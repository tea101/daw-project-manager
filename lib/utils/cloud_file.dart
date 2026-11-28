import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

/// Windows file attributes a cloud provider (OneDrive, Proton Drive, Google
/// Drive for desktop…) sets on a file that is only a placeholder here: its
/// contents come down the moment something reads them.
const _recallOnOpen = 0x40000;
const _recallOnDataAccess = 0x400000;
const _offline = 0x1000;
const _invalidAttributes = 0xFFFFFFFF;

/// Whether these attributes mark a cloud placeholder.
bool attributesSayCloudOnly(int attributes) =>
    attributes != _invalidAttributes &&
    attributes & (_recallOnOpen | _recallOnDataAccess | _offline) != 0;

/// Whether [path] is a cloud placeholder whose contents aren't on this
/// computer — reading it would download all of it. Asked of the file's
/// attributes only, which never downloads anything. Windows only: false
/// elsewhere, where a read just happens.
bool isCloudOnlyFile(String path) {
  if (Platform.isMacOS) return _macDataless(path);
  if (!Platform.isWindows) return false;
  final native = path.toNativeUtf16();
  try {
    return attributesSayCloudOnly(
      win32.GetFileAttributes(win32.PCWSTR(native)).value,
    );
  } finally {
    calloc.free(native);
  }
}

/// macOS's `SF_DATALESS` file flag: the file's contents live with a cloud
/// provider (iCloud Drive, or a File Provider drive in ~/Library/CloudStorage:
/// Dropbox, Google Drive, OneDrive…) and reading them would download them.
const int kMacDatalessFlag = 0x40000000;

/// Whether a macOS `stat` result marks a cloud-only file: the dataless flag
/// alone. A block count of zero is not used — some network shares report
/// none for files that are really there, and their audio would never be
/// read.
bool statSaysCloudOnly({required int flags}) => flags & kMacDatalessFlag != 0;

typedef _StatC = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _StatDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

_StatDart? _statFn;

/// Darwin's 64-bit `struct stat` (arm64 and x86_64 alike): `st_size` at 96,
/// `st_flags` at 116; 144 bytes in all. Asking for it
/// never touches the file's contents. The size read back is checked against
/// Dart's own, so a layout that doesn't match answers "not cloud-only"
/// rather than a guess.
bool _macDataless(String path) {
  Pointer<Utf8>? native;
  Pointer<Uint8>? buf;
  try {
    _statFn ??= DynamicLibrary.process().lookupFunction<_StatC, _StatDart>('stat');
    native = path.toNativeUtf8();
    buf = calloc<Uint8>(256);
    if (_statFn!(native, buf) != 0) return false;
    final data = ByteData.sublistView(Uint8List.fromList(buf.asTypedList(144)));
    final size = data.getInt64(96, Endian.little);
    final flags = data.getUint32(116, Endian.little);
    final known = File(path).statSync().size;
    if (size != known) return false;
    return statSaysCloudOnly(flags: flags);
  } catch (_) {
    return false;
  } finally {
    if (native != null) calloc.free(native);
    if (buf != null) calloc.free(buf);
  }
}
