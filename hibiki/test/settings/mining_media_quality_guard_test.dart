import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat;
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/source_guard.dart';

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
      // 动图链路。契约一个字没变：**喂进抽取器的帧率/宽度必须来自 compression 档位，
      // 不得被硬编码**，且换格式重试时必须夹到目标格式自己的顶格档上限。沿调用链锁三段：
      //   ① 实参里的 fps/width 不是字面量；
      //   ② 它们确实由 `compression.gifFps` / `compression.gifWidth` 派生；
      //   ③ 派生时夹到「本次尝试格式」自己的顶格档上限——换格式重试若沿用上一个格式的
      //      参数，就是 BUG-1039 那个 54 MB / 撞 120 秒超时 / AnkiConnect 卡死的配置。
      //
      // 锚点从调用形态换成**方法体**：BUG-1330（远端制卡接上动图格式偏好）把逐次抽取
      // 搬进 extractAnimatedClipWithFallback，引擎侧只剩 `extractor: _gif`，全文件再无
      // 原来那个调用形态，正则返回 null，守卫在**代码改对了的那一刻**炸掉（兄弟守卫
      // video_mining_context_guard_test 当时已改锚，本条被漏掉，develop 上一直红着）。
      // 锚方法体与调用形态无关；三段判据一条不减，而且比原来更强——不再要求「先派生成
      // 局部变量」这个中间形态，直接要求实参本身就是 compression 派生且按 attempt 夹取。
      final String fallbackBody = methodBody(
        src,
        'Future<AnimatedClipExtraction?> extractAnimatedClipWithFallback(',
      );
      expect(fallbackBody.contains('await extractor('), isTrue,
          reason: '动图链路必须经注入的抽取器（引擎侧传 extractor: _gif）');
      expect(fallbackBody.contains('fps: attempt.capFps(compression.gifFps)'),
          isTrue,
          reason: '帧率必须由 compression.gifFps 派生并夹到本次格式上限（BUG-1039）');
      expect(
          fallbackBody
              .contains('width: attempt.capWidth(compression.gifWidth)'),
          isTrue,
          reason: '宽度必须由 compression.gifWidth 派生并夹到本次格式上限（BUG-1039）');
      expect(src.contains('extractor: _gif'), isTrue,
          reason: '引擎必须把自己注入的 _gif 抽取器交给 fallback 链，测试才能替身');
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

    // 动图格式偏好的**接线**守卫。默认值（`MiningAnimatedFormat.gif`）铺在
    // `mineLine` / `ImmersionMiningRequest` / `resolve` 三处形参上，是为了让未改的
    // 既有调用点逐字节等价——代价是**漏传不会报错，只会静默退回旧行为**：用户在设置
    // 里选了 AVIF，某个入口照样出 GIF，没有任何日志。gal 制卡的浮窗入口一度就是这样
    // 漏的（texthooker 入口接了、浮窗入口没接，同一个偏好两种结果）。
    //
    // 这条锁的是「每个真实入口都显式透传偏好」，不是「源码里有这行字」：断言的是
    // `<形参>: <AppModel 偏好 getter>` 的配对，把值换成字面量或换成另一个域的偏好
    // 都会红。
    test('每个制卡入口都显式透传动图格式偏好（漏传只会静默退回 GIF）', () {
      // 入口源码 -> (该入口该用的 AppModel 偏好 getter, 该入口持有 AppModel 的变量名)
      const Map<String, (String, String)> entries = <String, (String, String)>{
        'lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart': (
          'videoMiningAnimatedFormat',
          'appModel',
        ),
        'lib/src/pages/implementations/texthooker_page.dart': (
          'galMiningAnimatedFormat',
          'mixinAppModel',
        ),
        'lib/src/lookup/gal_hook_text_overlay_controller.dart': (
          'galMiningAnimatedFormat',
          'model',
        ),
      };
      entries.forEach((String path, (String, String) wiring) {
        final (String getter, String owner) = wiring;
        final String src = File(path).readAsStringSync();
        final String pref = '$owner.$getter';
        // 允许把偏好先落成局部变量再传（视频入口要传两处，本来就该只读一次）。
        // 允许集 = 偏好本身 + 所有**由该偏好初始化**的 MiningAnimatedFormat 局部变量；
        // 换成字面量、换成另一个域的偏好、换成无关局部变量都不在集里 → 红。
        final Set<String> allowed = <String>{pref};
        for (final RegExpMatch m in RegExp(
                r'final MiningAnimatedFormat (\w+)\s*=\s*([^;]*);',
                multiLine: true)
            .allMatches(src)) {
          if (m.group(2)!.contains(pref)) allowed.add(m.group(1)!);
        }
        for (final String param in <String>['format', 'animatedFormat']) {
          final Iterable<String> actual = RegExp('\\b$param:\\s*([\\w.]+)')
              .allMatches(src)
              .map((RegExpMatch m) => m.group(1)!);
          expect(
            actual.isNotEmpty && actual.every(allowed.contains),
            isTrue,
            reason: '$path 的 `$param:` 实参必须是 $pref（或由它派生的局部变量），'
                '实际是 ${actual.isEmpty ? "（一个都没传）" : actual.toSet()}；'
                '漏传时形参默认 gif，用户选的格式静默失效',
          );
        }
      });
    });

    // 动图格式是「文件长什么样」，它必须能被 MIME 表认出来。编码器缺失有 fail-open
    // 降级兜底，**渲染端认不出没有任何兜底**：卡已经写进 Anki 了，用户看到的是永久
    // 破图。`.webp` 缺项就是 BUG-1122 的原始形态，`.avif` 是同一个坑的下一个入口。
    test('每种动图格式的扩展名都在两张 MIME 表里（BUG-1122 同款）', () {
      final String core = File(
        '../packages/hibiki_core/lib/src/utils/mime_types.dart',
      ).readAsStringSync();
      final String anki = File(
        '../packages/hibiki_anki/lib/src/anki_models.dart',
      ).readAsStringSync();
      for (final MiningAnimatedFormat format in MiningAnimatedFormat.values) {
        final String ext = format.fileExtension;
        expect(RegExp("'$ext':\\s*'image/").hasMatch(core), isTrue,
            reason: 'hibiki_core 的 MIME 表缺 $ext（$format 的产出扩展名）');
        expect(RegExp("'$ext':\\s*'image/").hasMatch(anki), isTrue,
            reason: 'hibiki_anki 的 MIME 镜像表缺 $ext（$format 的产出扩展名）');
      }
    });
  });
}
