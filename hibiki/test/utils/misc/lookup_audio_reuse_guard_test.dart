import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-744: 查词音频「要等一会才出来」= 真实串行 IO 叠加。这一组源码守卫钉住
/// 三处复用优化，防止回归到「每次都重新建」的慢路径：
///   ③ HibikiRemoteLookupClient 共用单个缓存的 http.Client（复用 TLS 连接）。
///   ① Android TtsChannelHandler 复用单个 MediaPlayer（reset 而非每次 new）。
///   ④（行为测试见 local_audio_db_blob_skip_test）本地 blob 已存在即跳过重写。
String _read(String path) => File(path).readAsStringSync();

void main() {
  group('③ remote lookup http.Client is cached & shared', () {
    final String src = _read('lib/src/models/app_model.dart');
    final String flat = src.replaceAll(RegExp(r'\s+'), ' ');

    test('a single http.Client is lazily cached, not new per lookup', () {
      expect(src, contains('http.Client? _remoteLookupHttpClient'),
          reason: 'the client must be a cached field, not a local');
      expect(flat, contains('_remoteLookupHttpClient ??= http.Client()'),
          reason: 'lazy-init exactly one client and reuse it');
    });

    test('both lookup call sites pass the shared client in', () {
      // Each HibikiRemoteLookupClient(...) must receive the cached client so it
      // does not fall back to its own per-instance http.Client().
      final int passes =
          RegExp(r'httpClient:\s*_remoteLookupClient').allMatches(src).length;
      expect(passes, 2,
          reason: 'dictionary + audio lookups both reuse the one client');
    });

    test('the cached client is closed on dispose', () {
      expect(flat, contains('_remoteLookupHttpClient?.close()'),
          reason: 'the reused client must be released on dispose');
    });
  });

  group('① Android MediaPlayer is reused via reset(), not new per play', () {
    final String java = _read(
        'android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java');
    final String flat = java.replaceAll(RegExp(r'\s+'), ' ');

    test('play paths go through a shared startPlayback that resets', () {
      expect(flat, contains('private void startPlayback('),
          reason: 'playUrl/playFile must funnel through one reuse path');
      expect(flat, contains('ensureMediaPlayer()'),
          reason: 'the single instance must be lazily ensured, not new-ed '
              'inside each play handler');
    });

    test('no per-play "new MediaPlayer()" in the play handlers', () {
      // The only allowed construction site is ensureMediaPlayer().
      final int constructions =
          RegExp(r'new\s+MediaPlayer\s*\(\s*\)').allMatches(java).length;
      expect(constructions, 1,
          reason: 'exactly one construction site (ensureMediaPlayer); play '
              'handlers must reset() and reuse');
    });

    test('a generation guard protects superseded async callbacks', () {
      expect(java, contains('playGeneration'),
          reason: 'stale prepare/completion callbacks must bail on a newer '
              'play/stop so they do not act on the reused player');
      expect(flat, contains('generation != playGeneration'),
          reason: 'callbacks must compare their captured generation');
    });

    test('completion does not release the reused instance', () {
      // release() must only happen in destroy(); completion/stop reuse via
      // reset(). Guard: reset-based recycle helper exists and is used.
      expect(flat, contains('resetMediaPlayerQuietly()'),
          reason: 'completion/error/stop recycle the instance with reset(), '
              'not release()');
    });
  });
}
