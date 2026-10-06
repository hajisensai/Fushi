import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:fushi_engine/media/video/bluray/aacs_stream_relay.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_encryption.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:path/path.dart' as p;

/// Native workers may report late errors after their owning session was closed.
/// Scrub this capability shape even when its original path is no longer known.
String redactAacsRelayUrls(String value) => value.replaceAll(
  RegExp(r'http://127\.0\.0\.1:\d+/[A-Za-z0-9_-]{43}=/stream\.m2ts'),
  '[decrypted Blu-ray]',
);

/// 本进程是否装配 AACS 解密（商店合规门）。
///
/// 唯一判据在 app 的 `StoreRestrictedCapability.aacsDecryption`（iOS 不装配），
/// `installEngineHostBindings()` 用它赋值；引擎不能 import app，所以这里只是装配点。
/// 默认值按同一判据 **fail-closed**：Dart 全局变量带不过 isolate 边界，后台 isolate
/// 里同样会经 `resolveFfmpegBackend()` 建会话，没人赋值时 iOS 也绝不读取 / 下载
/// 播放配置。关闭时加密码流报 [BlurayEncryptedStreamException]（接入解密前的行为）。
bool aacsDecryptionAvailable = !Platform.isIOS;

/// Owns decrypted inputs for one playback or FFmpeg command. Persistent media
/// identities stay on disk; loopback capabilities are never written to the DB.
class AacsMediaSession {
  final Map<String, Future<AacsStreamRelay?>> _streams =
      <String, Future<AacsStreamRelay?>>{};
  final Map<
    String,
    Future<({Uint8List unitKeyFile, Uint8List volumeUniqueKey})>
  >
  _configurations = {};
  final Map<String, String> _resolvedUrls = {};
  Future<void>? _closing;
  bool _closed = false;
  bool _hasProtectedStreams = false;
  bool get hasProtectedStreams => _hasProtectedStreams;

  Future<String> resolve(String path) async {
    if (_closed) throw StateError('Media session is closed');
    if (!isBdavStreamPath(path)) return path;
    final Future<AacsStreamRelay?> pending = _streams.putIfAbsent(
      path,
      () => _open(path),
    );
    final AacsStreamRelay? relay = await pending;
    if (relay != null) {
      _hasProtectedStreams = true;
      _resolvedUrls[relay.url] = path;
    }
    if (_closed) {
      await relay?.close();
      throw StateError('Media session is closed');
    }
    return relay?.url ?? path;
  }

  Future<AacsStreamRelay?> _open(String path) async {
    if (!await isAacsEncryptedStreamFile(path)) return null;
    if (!aacsDecryptionAvailable) throw BlurayEncryptedStreamException(path);
    final String? root = blurayDiscRootForFile(path);
    if (root == null || await Directory(p.join(root, 'BDSVM')).exists()) {
      throw const AacsConfigurationException(
        AacsConfigurationError.unsupportedDisc,
      );
    }
    final configuration = await _configurations.putIfAbsent(
      root,
      () => loadAacsConfiguration(root),
    );
    if (_closed) throw StateError('Media session is closed');
    try {
      return await AacsStreamRelay.open(
        streamPath: path,
        unitKeyFile: configuration.unitKeyFile,
        volumeUniqueKey: configuration.volumeUniqueKey,
      );
    } on StateError {
      throw const AacsConfigurationException(
        AacsConfigurationError.invalidConfiguration,
      );
    }
  }

  Future<String> playbackSource(BluraySource source) async {
    if (source.isPlainFile) return resolve(source.primaryStreamPath);
    String uri = source.uri;
    for (final String path in source.streamPaths) {
      final String resolved = await resolve(path);
      if (resolved != path) {
        uri = uri.replaceAll(encodeEdlField(path), encodeEdlField(resolved));
      }
    }
    return uri;
  }

  Future<List<String>> ffmpegInputs(
    List<String> args, {
    bool probe = false,
  }) async {
    final List<String> result = List<String>.of(args);
    for (int i = 0; i < result.length; i++) {
      if ((i > 0 && result[i - 1] == '-i') ||
          (probe && i == result.length - 1)) {
        result[i] = await resolve(result[i]);
      }
    }
    return result;
  }

  /// Scrub short-lived input URLs before logs or metadata can retain them.
  /// The replacement is JSON-safe for ffprobe's format.filename field.
  String redact(String value) {
    for (final entry in _resolvedUrls.entries) {
      value = value.replaceAll(entry.key, '[decrypted Blu-ray]');
    }
    return redactAacsRelayUrls(value);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    for (final Future<AacsStreamRelay?> pending in _streams.values) {
      AacsStreamRelay? relay;
      try {
        relay = await pending;
      } catch (_) {
        // A failed open has no retained stream; its caller receives the error.
        continue;
      }
      await relay?.close();
    }
    _streams.clear();
    _configurations.clear();
  }
}
