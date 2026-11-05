import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Dart FFI binding to the `hm-remote` Rust library (the same crate the desktop
/// uses), running this phone's **iroh** endpoint so a desktop can stream its
/// library across *different* networks.
///
/// The native node serves the media tunnel into the phone's local HTTP shelf
/// (so `/library`, `/stream`, … work unchanged through iroh), and dials the
/// desktop to pair when the user scans its QR.
///
/// Build the native library with `scripts/build_remote_android.sh` (see
/// `docs/remote-link-phone.md`); it lands in `android/app/src/main/jniLibs/`.

// --- C signatures ---
typedef _StartC = Pointer<Void> Function(Pointer<Utf8>, Uint16);
typedef _StartD = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _EndpointIdC = Pointer<Utf8> Function(Pointer<Void>);
typedef _EndpointIdD = Pointer<Utf8> Function(Pointer<Void>);
typedef _PairC = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _PairD = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _StopC = Void Function(Pointer<Void>);
typedef _StopD = void Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);

/// Open the platform's native library. The same `.so`/`.dylib` is loadable from
/// any isolate (the process loads it once), so the background pairing isolate
/// re-opens it freely.
DynamicLibrary _openLib() {
  if (Platform.isAndroid) return DynamicLibrary.open('libhm_remote.so');
  if (Platform.isMacOS) return DynamicLibrary.open('libhm_remote.dylib');
  if (Platform.isIOS) return DynamicLibrary.process(); // statically linked
  throw UnsupportedError('Remote link is not supported on this platform.');
}

/// Whether the platform can load the native library at all.
bool get remoteLinkSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

class RemoteLink {
  RemoteLink._();
  static final RemoteLink instance = RemoteLink._();

  DynamicLibrary? _lib;
  Pointer<Void>? _node;

  late final _start = _lib!.lookupFunction<_StartC, _StartD>('hm_phone_start');
  late final _endpointId = _lib!.lookupFunction<_EndpointIdC, _EndpointIdD>(
    'hm_phone_endpoint_id',
  );
  late final _stop = _lib!.lookupFunction<_StopC, _StopD>('hm_phone_stop');
  late final _free = _lib!.lookupFunction<_FreeC, _FreeD>('hm_string_free');

  bool get running => _node != null;

  /// Start the iroh endpoint with a stable identity from `secretPath`, serving
  /// the media tunnel into the local shelf at `127.0.0.1:shelfPort`. Idempotent.
  Future<void> start(String secretPath, int shelfPort) async {
    if (_node != null) return;
    try {
      _lib ??= _openLib();
    } catch (e) {
      debugPrint('RemoteLink: native library unavailable: $e');
      return;
    }
    final pathC = secretPath.toNativeUtf8();
    try {
      final node = _start(pathC, shelfPort);
      if (node == nullptr) {
        debugPrint('RemoteLink: failed to start node');
        return;
      }
      _node = node;
    } finally {
      malloc.free(pathC);
    }
  }

  /// This phone's stable iroh id (or null if not started).
  String? endpointId() {
    final n = _node;
    if (n == null) return null;
    final p = _endpointId(n);
    if (p == nullptr) return null;
    final s = p.toDartString();
    _free(p);
    return s;
  }

  /// Pair with the desktop scanned from its QR. `token` is the bearer token the
  /// shelf has authorised for this desktop (see `registerDesktop`). Runs the
  /// blocking handshake off the UI isolate. Returns the desktop's name, or null
  /// on failure.
  Future<String?> pair({
    required String desktopEndpointId,
    required String pin,
    required String phoneName,
    required String token,
  }) async {
    final n = _node;
    if (n == null) return null;
    final nodeAddr = n.address;
    return Isolate.run(
      () => _pairBlocking(nodeAddr, desktopEndpointId, pin, phoneName, token),
    );
  }

  /// Stop the node (e.g. when sharing is disabled).
  Future<void> stop() async {
    final n = _node;
    if (n == null) return;
    _node = null;
    _stop(n);
  }
}

/// Runs on a background isolate: re-open the library, call the blocking pair
/// FFI, and return the desktop name (or null). Only sendable args (ints/strings).
String? _pairBlocking(
  int nodeAddr,
  String desktopEp,
  String pin,
  String name,
  String token,
) {
  final lib = _openLib();
  final pairFn = lib.lookupFunction<_PairC, _PairD>('hm_phone_pair');
  final freeFn = lib.lookupFunction<_FreeC, _FreeD>('hm_string_free');
  final node = Pointer<Void>.fromAddress(nodeAddr);
  final epC = desktopEp.toNativeUtf8();
  final pinC = pin.toNativeUtf8();
  final nameC = name.toNativeUtf8();
  final tokenC = token.toNativeUtf8();
  try {
    final res = pairFn(node, epC, pinC, nameC, tokenC);
    if (res == nullptr) return null;
    final s = res.toDartString();
    freeFn(res);
    return s;
  } finally {
    malloc.free(epC);
    malloc.free(pinC);
    malloc.free(nameC);
    malloc.free(tokenC);
  }
}
