import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-757 守卫：压缩制卡媒体开关。
///
/// 锁住四层契约（不依赖真机 / WebView / ffmpeg）：
/// 1. 偏好默认 true=压缩档（保持现状=Never break userspace）+ toggle 写穿 Drift；
/// 2. MiningMediaCompression 两档参数与选档语义（开=压缩档，关=高保真档）；
/// 3. 三条媒体链路调用点（GIF / 截图 / 视频音频 + 阅读器句子音频）都读
///    `compressMiningMedia` 并把选档喂进底层；
/// 4. Anki 设置页有这个开关行，wire 到 AppModel.compressMiningMedia。

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('偏好层', () {
    late HibikiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('默认 true（压缩档=保持现状）', () {
      expect(repo.compressMiningMedia, isTrue);
    });

    test('toggle 写穿 Drift（往返 + DB key）', () async {
      repo.toggleCompressMiningMedia();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.compressMiningMedia, isFalse);

      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.compressMiningMedia, isFalse, reason: '关闭后必须落盘且跨实例可见');

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('compress_mining_media'), isTrue,
          reason: 'DB key 必须是 compress_mining_media');

      restored.dispose();
    });
  });

  group('MiningMediaCompression 选档语义', () {
    test('开 → 压缩档，关 → 高保真档', () {
      expect(MiningMediaCompression.forCompressionEnabled(true),
          same(MiningMediaCompression.compressed));
      expect(MiningMediaCompression.forCompressionEnabled(false),
          same(MiningMediaCompression.highFidelity));
    });

    test('压缩档=现状，高保真档更大', () {
      const MiningMediaCompression c = MiningMediaCompression.compressed;
      const MiningMediaCompression h = MiningMediaCompression.highFidelity;
      expect(h.audioChannels, greaterThan(c.audioChannels));
      expect(h.gifFps, greaterThan(c.gifFps));
      expect(h.gifWidth, greaterThan(c.gifWidth));
      expect(h.screenshotMaxLongEdge, greaterThan(c.screenshotMaxLongEdge));
      expect(h.screenshotQuality, greaterThan(c.screenshotQuality));
    });
  });

  group('调用点源码守卫', () {
    test('视频 mining 三条链路读 compressMiningMedia 并选档', () {
      final String src = File(
        'lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart',
      ).readAsStringSync();

      // 选档一次，三条链路共用。
      expect(
        src.contains('MiningMediaCompression.forCompressionEnabled') &&
            src.contains('appModel.compressMiningMedia'),
        isTrue,
        reason: '视频 mining 必须据 appModel.compressMiningMedia 选档',
      );
      // GIF 链路传 fps/width。
      expect(src.contains('fps: mediaCompression.gifFps'), isTrue);
      expect(src.contains('width: mediaCompression.gifWidth'), isTrue);
      // 截图链路传 maxLongEdge/quality。
      expect(
          src.contains('maxLongEdge: mediaCompression.screenshotMaxLongEdge'),
          isTrue);
      expect(
          src.contains('quality: mediaCompression.screenshotQuality'), isTrue);
      // 音频链路传 channels/bitrate。
      expect(src.contains('audioChannels: mediaCompression.audioChannels'),
          isTrue);
      expect(
          src.contains('audioBitrate: mediaCompression.audioBitrate'), isTrue);
    });

    test('阅读器句子音频读 compressMiningMedia 并传桌面 ffmpeg 档', () {
      final String src = File(
        'lib/src/pages/implementations/reader_hibiki/mining.part.dart',
      ).readAsStringSync();
      expect(
        src.contains('MiningMediaCompression.forCompressionEnabled') &&
            src.contains('appModel.compressMiningMedia'),
        isTrue,
        reason: '阅读器句子音频必须据 appModel.compressMiningMedia 选档',
      );
      expect(src.contains('audioChannels: mediaCompression.audioChannels'),
          isTrue);
      expect(
          src.contains('audioBitrate: mediaCompression.audioBitrate'), isTrue);
    });

    test('Anki 设置页有压缩开关行 wire 到 AppModel.compressMiningMedia', () {
      final String src = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      expect(src.contains('t.compress_mining_media'), isTrue,
          reason: '开关标题用 i18n key compress_mining_media');
      expect(src.contains('appModel.compressMiningMedia'), isTrue);
      expect(src.contains('appModel.toggleCompressMiningMedia()'), isTrue);
    });
  });
}
