import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:fushi_engine/media/video/bluray/bluray_encryption.dart';
import 'package:path/path.dart' as p;

/// The bundled `native/fushi_aacs` module that libbluray loads as libaacs.
///
/// libbluray reads every menu, IG and title stream of an AACS disc through
/// libaacs; Fushi's own decryptor (AacsMediaSession) only feeds titles it
/// opens itself. The module carries no key policy: the app registers the exact
/// disc-ID VUK resolved by [loadAacsConfiguration] before opening the disc.
abstract interface class BlurayAacsModule {
  /// [discId] is SHA-1(`AACS/Unit_Key_RO.inf`). A null [volumeUniqueKey]
  /// records the app's verdict that the disc's streams are already clear.
  void setDiscKey(Uint8List discId, Uint8List? volumeUniqueKey);
}

/// Bumped together with FUSHI_AACS_ABI_VERSION in native/fushi_aacs.
const int kFushiAacsAbiVersion = 1;

/// File name each platform's libbluray resolves (see native/fushi_aacs).
/// Android ships an APK-safe name whose soname is `libaacs.so.0`; loading it
/// here first lets bionic satisfy libbluray's later `dlopen("libaacs.so.0")`.
String? fushiAacsLibraryName() {
  if (Platform.isWindows) return 'libaacs.dll';
  if (Platform.isAndroid) return 'libfushi_aacs.so';
  if (Platform.isMacOS) return 'libaacs.dylib';
  return null;
}

BlurayAacsModule? _module;
bool _moduleResolved = false;

/// The process-wide module, or null where it is not bundled (Linux uses the
/// system libmpv/libbluray and whatever libaacs that system provides).
BlurayAacsModule? loadBlurayAacsModule() {
  if (_moduleResolved) return _module;
  _moduleResolved = true;
  final String? name = fushiAacsLibraryName();
  if (name == null) return null;
  try {
    _module = _FfiBlurayAacsModule(DynamicLibrary.open(name));
  } on Object {
    _module = null;
  }
  return _module;
}

typedef _SetDiscKeyNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _SetDiscKeyDart = int Function(Pointer<Uint8>, Pointer<Uint8>);

final class _FfiBlurayAacsModule implements BlurayAacsModule {
  _FfiBlurayAacsModule(DynamicLibrary library)
    : _setDiscKey = library.lookupFunction<_SetDiscKeyNative, _SetDiscKeyDart>(
        'fushi_aacs_set_disc_key',
      ) {
    final int version = library
        .lookupFunction<Int32 Function(), int Function()>(
          'fushi_aacs_abi_version',
        )();
    if (version != kFushiAacsAbiVersion) {
      throw StateError('fushi_aacs ABI $version != $kFushiAacsAbiVersion');
    }
  }

  final _SetDiscKeyDart _setDiscKey;

  @override
  void setDiscKey(Uint8List discId, Uint8List? volumeUniqueKey) {
    if (discId.length != 20) throw ArgumentError.value(discId, 'discId');
    if (volumeUniqueKey != null && volumeUniqueKey.length != 16) {
      throw ArgumentError('volume unique key must be 16 bytes');
    }
    final Pointer<Uint8> id = calloc<Uint8>(20);
    final Pointer<Uint8> key = volumeUniqueKey == null
        ? nullptr
        : calloc<Uint8>(16);
    try {
      id.asTypedList(20).setAll(0, discId);
      if (volumeUniqueKey != null) {
        key.asTypedList(16).setAll(0, volumeUniqueKey);
      }
      _setDiscKey(id, key);
    } finally {
      if (key != nullptr) {
        key.asTypedList(16).fillRange(0, 16, 0);
        calloc.free(key);
      }
      calloc.free(id);
    }
  }
}

/// How an opened disc menu will satisfy libbluray's AACS requirement.
enum BlurayMenuAacsState {
  /// No `AACS/Unit_Key_RO.inf`: libbluray never loads libaacs.
  notProtected,

  /// The module holds this disc's VUK; menus and titles decrypt natively and
  /// the same KEYDB entry lets the shared FFmpeg backend extract titles.
  keyed,

  /// AACS metadata remains but every stream is already clear.
  clear,

  /// No bundled module on this platform; the system's libaacs (if any)
  /// decides, and a failure surfaces as a native open error.
  unmanaged,
}

typedef BlurayAacsConfigurationLoader =
    Future<({Uint8List unitKeyFile, Uint8List volumeUniqueKey})> Function(
      String discRoot,
    );

/// Registers [discRoot]'s key with the module before libbluray opens it.
///
/// Throws the [AacsConfigurationException] of the KEYDB lookup when the disc
/// has encrypted streams but no usable key, so the page reports the same
/// KEYDB guidance as title playback instead of opening a black menu.
Future<BlurayMenuAacsState> prepareBlurayMenuAacs(
  String discRoot, {
  BlurayAacsModule? Function() module = loadBlurayAacsModule,
  BlurayAacsConfigurationLoader loadConfiguration = loadAacsConfiguration,
  Future<bool> Function(String streamPath) isEncryptedStream =
      isAacsEncryptedStreamFile,
}) async {
  final File unitFile = File(p.join(discRoot, 'AACS', 'Unit_Key_RO.inf'));
  if (!await unitFile.exists()) return BlurayMenuAacsState.notProtected;
  final BlurayAacsModule? native = module();
  if (native == null) return BlurayMenuAacsState.unmanaged;
  try {
    final ({Uint8List unitKeyFile, Uint8List volumeUniqueKey}) configuration =
        await loadConfiguration(discRoot);
    native.setDiscKey(
      Uint8List.fromList(sha1.convert(configuration.unitKeyFile).bytes),
      configuration.volumeUniqueKey,
    );
    return BlurayMenuAacsState.keyed;
  } on AacsConfigurationException {
    if (await _hasEncryptedStream(discRoot, isEncryptedStream)) rethrow;
  }
  native.setDiscKey(
    Uint8List.fromList(sha1.convert(await unitFile.readAsBytes()).bytes),
    null,
  );
  return BlurayMenuAacsState.clear;
}

/// Menus also read clips no title list references, so every stream counts.
Future<bool> _hasEncryptedStream(
  String discRoot,
  Future<bool> Function(String streamPath) isEncryptedStream,
) async {
  final Directory streams = Directory(p.join(discRoot, 'BDMV', 'STREAM'));
  if (!streams.existsSync()) return false;
  // listSync: an async directory stream never completes under fake-async
  // widget tests that reach this through the player page.
  for (final FileSystemEntity entity in streams.listSync()) {
    if (entity is File &&
        isBdavStreamPath(entity.path) &&
        await isEncryptedStream(entity.path)) {
      return true;
    }
  }
  return false;
}
