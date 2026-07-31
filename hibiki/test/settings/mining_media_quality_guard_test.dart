import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1650 守卫：制卡图片/GIF 清晰度 + 音频质量两滑块（替代旧「压缩」开关）。
///
/// 锁住四层契约（不依赖真机 / WebView / ffmpeg）：
/// 1. 偏好默认 = 旧压缩档（图片档 1 / 音频档 0，保持现状=Never break userspace）+ 从旧
///    `compress_mining_media` 布尔迁移（关闭压缩→图片高清档 2 / 音频高音质档 1）+ 写穿 Drift；
/// 2. [MiningMediaCompression.resolve] 据两档组装参数、越界夹取、原片档用 0 哨兵；
/// 3. 三条媒体链路调用点（video / reader 句子音频 / texthooker）都读 miningImageQuality
///    /miningAudioQuality 经 resolve 选档并把档喂进底层；
/// 4. Anki 设置页有这两个滑块行，wire 到 AppModel.miningImageQuality / miningAudioQuality。

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

    test('默认 = 旧压缩档（图片档 1 / 音频档 0，保持现状）', () {
      expect(repo.miningImageQuality, MiningMediaCompression.defaultImageTier);
      expect(repo.miningAudioQuality, MiningMediaCompression.defaultAudioTier);
    });

    test('从旧 compress_mining_media=false 迁移到高保真档（图片 2 / 音频 1）', () async {
      // 老用户显式关过压缩（highFidelity）：新档位键未设时应从旧布尔推导，不丢偏好。
      await db.setPref('compress_mining_media', PrefCodec.encode(false));
      final PreferencesRepository migrated = PreferencesRepository(db);
      await migrated.loadFromDb();
      expect(migrated.miningImageQuality, 2, reason: '旧关闭压缩=图片高清档 2');
      expect(migrated.miningAudioQuality, 1, reason: '旧关闭压缩=音频高音质档 1');
      migrated.dispose();
    });

    test('setMiningImageQuality 写穿 Drift（往返 + DB key + 越界夹取）', () async {
      repo.setMiningImageQuality(3);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningImageQuality, 3);

      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.miningImageQuality, 3, reason: '设过必须落盘且跨实例可见');

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('mining_image_quality'), isTrue,
          reason: 'DB key 必须是 mining_image_quality');
      restored.dispose();

      repo.setMiningImageQuality(99); // 越界
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningImageQuality, MiningMediaCompression.imageTierCount - 1,
          reason: '越界写入必须夹到满档');
    });

    test('setMiningAudioQuality 写穿 Drift（往返 + DB key + 越界夹取）', () async {
      repo.setMiningAudioQuality(2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioQuality, 2);

      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.miningAudioQuality, 2, reason: '设过必须落盘且跨实例可见');

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('mining_audio_quality'), isTrue,
          reason: 'DB key 必须是 mining_audio_quality');
      restored.dispose();

      repo.setMiningAudioQuality(-5); // 越界
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.miningAudioQuality, 0, reason: '越界写入必须夹到 0');
    });
  });

  group('MiningMediaCompression.resolve 组装语义', () {
    test('默认档（图片 1 + 音频 0）= 旧压缩档现状', () {
      final MiningMediaCompression r = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.defaultImageTier,
        audioTier: MiningMediaCompression.defaultAudioTier,
      );
      expect(r.screenshotMaxLongEdge, 1000);
      expect(r.screenshotQuality, 90);
      expect(r.gifWidth, 480);
      expect(r.gifFps, 8);
      expect(r.audioChannels, 1);
      expect(r.audioBitrate, '64k');
    });

    test('满档（图片原片 + 音频原片）= 截图 0 哨兵 + GIF 封顶 + 立体声 192k', () {
      final MiningMediaCompression r = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.imageTierMax,
        audioTier: MiningMediaCompression.audioTierCount - 1,
      );
      expect(r.screenshotMaxLongEdge, 0, reason: '0 = 不缩放（原图直通）');
      // BUG-1039：GIF 侧不存在「源分辨率/源帧率」档——GIF 无帧间压缩，0 哨兵会让
      // 1080p 源的 4 秒区间涨到 54 MB / 48.9 秒，把 Anki 打成无响应。
      expect(r.gifWidth, MiningMediaCompression.gifMaxTierWidth);
      expect(r.gifFps, MiningMediaCompression.gifMaxTierFps);
      expect(r.audioChannels, 2);
      expect(r.audioBitrate, '192k');
    });
  });

  group('调用点源码守卫', () {
    test('视频 mining 据两档 resolve 并把档喂进引擎（TODO-1000 收口）', () {
      final String src = File(
        'lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart',
      ).readAsStringSync();
      expect(
        src.contains('MiningMediaCompression.resolve') &&
            src.contains('imageTier: appModel.miningImageQuality') &&
            src.contains('audioTier: appModel.miningAudioQuality'),
        isTrue,
        reason: '视频 mining 必须据两档 resolve 选档',
      );
      expect(src.contains('compression: mediaCompression'), isTrue,
          reason: '选好的档必须喂进 ImmersionMiningEngine.mine');
    });

    test('ImmersionMiningEngine 把档应用到三条媒体链路', () {
      final String src = File(
        'lib/src/mining/immersion_mining_engine.dart',
      ).readAsStringSync();
      // 动图链路。档位仍必须被读出并喂给抽取器，但**不再是**直接
      // `fps: compression.gifFps`：顶格档的 0 哨兵（源分辨率+源帧率，只有 AVIF 声明
      // 得起）在换格式重试时必须替换成目标格式自己的顶格档参数，否则会把源直通喂给
      // GIF —— 正是 BUG-1039 那个 54 MB / 撞 120 秒超时的配置。故断言拆成两半：
      // ① 档位被读；② 替换存在。只锁 ① 会漏掉 ② 被删除的回归。
      expect(src.contains('compression.gifFps'), isTrue);
      expect(src.contains('compression.gifWidth'), isTrue);
      expect(src.contains('attempt.maxTierFps'), isTrue,
          reason: '换格式重试必须换用目标格式的顶格档参数（BUG-1039）');
      expect(src.contains('attempt.maxTierWidth'), isTrue,
          reason: '换格式重试必须换用目标格式的顶格档参数（BUG-1039）');
      // 截图链路。
      expect(src.contains('maxLongEdge: compression.screenshotMaxLongEdge'),
          isTrue);
      expect(src.contains('quality: compression.screenshotQuality'), isTrue);
      // 音频链路。
      expect(src.contains('audioChannels: compression.audioChannels'), isTrue);
      expect(src.contains('audioBitrate: compression.audioBitrate'), isTrue);
    });

    test('阅读器句子音频据两档 resolve 并传桌面 ffmpeg 档', () {
      final String src = File(
        'lib/src/pages/implementations/reader_hibiki/mining.part.dart',
      ).readAsStringSync();
      expect(
        src.contains('MiningMediaCompression.resolve') &&
            src.contains('imageTier: appModel.miningImageQuality') &&
            src.contains('audioTier: appModel.miningAudioQuality'),
        isTrue,
        reason: '阅读器句子音频必须据两档 resolve 选档',
      );
      expect(src.contains('audioChannels: mediaCompression.audioChannels'),
          isTrue);
      expect(
          src.contains('audioBitrate: mediaCompression.audioBitrate'), isTrue);
    });

    test('Anki 设置页有两滑块行 wire 到 AppModel 两档', () {
      final String src = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      expect(src.contains('t.mining_image_quality'), isTrue,
          reason: '图片滑块标题用 i18n key mining_image_quality');
      expect(src.contains('t.mining_audio_quality'), isTrue,
          reason: '音频滑块标题用 i18n key mining_audio_quality');
      expect(src.contains('appModel.setMiningImageQuality'), isTrue);
      expect(src.contains('appModel.setMiningAudioQuality'), isTrue);
    });

    // BUG-1039：两个滑块的满档过去都叫「原片 / Native」，但都名不副实——图片满档对 GIF
    // 已是封顶档（只有截图仍是原图），音频满档 192k AAC 本就是有损重编码。统一改叫
    // 「最高 / Maximum」（只承诺是滑块顶格，不承诺保真度）。钉死不许滑回旧名。
    test('BUG-1039：两滑块满档标签是「最高」而非名不副实的「原片」', () {
      final String src = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      expect(src.contains('t.mining_image_quality_max'), isTrue,
          reason: '图片满档标签必须用 mining_image_quality_max');
      expect(src.contains('t.mining_audio_quality_max'), isTrue,
          reason: '音频满档标签必须用 mining_audio_quality_max');
      expect(src.contains('t.mining_image_quality_native'), isFalse,
          reason: '「原片」是名不副实的旧名，不得复活');
      expect(src.contains('t.mining_audio_quality_native'), isFalse,
          reason: '「原片」是名不副实的旧名，不得复活');
    });
  });
}
