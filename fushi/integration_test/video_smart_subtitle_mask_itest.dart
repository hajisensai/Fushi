/// 智能遮布真机 E2E：真 app + 真 libmpv + 真本机 OCR 模型，播一段带烧录中文字幕的视频，
/// 遮布只在有字的时段出现、盖在字幕行上，左上角常驻的招牌字（搜索区域外）不盖。
///
/// 需要本机素材（不入库）：
///
///   --dart-define=OCR_MODEL_SEED=<当前默认本机模型的目录（ocr_models/manga-ctc）>
///   --dart-define=DESUB_FIXTURE=<1280x720、12 s 视频：1–4 s 与 6–9.5 s 底部有中文
///       字幕，左上角常驻招牌字>
///
/// 缺素材时跳过。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_mask.dart';
import 'package:fushi/src/media/video/video_subtitle_mask_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _modelSeed = String.fromEnvironment('OCR_MODEL_SEED');
const String _fixture = String.fromEnvironment('DESUB_FIXTURE');
const String _kBookUid = 'video/itest-smart-subtitle-mask';

/// 一次观测：播放位置、遮布是否（正在）可见、遮布在视口里的矩形。
typedef _Obs = ({int positionMs, bool visible, Rect? rect});

_Obs? _observe(WidgetTester tester) {
  final Finder page = find.byType(VideoFushiPage);
  if (page.evaluate().isEmpty) return null;
  final VideoFushiTestHooks hooks =
      tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
  final int? position = hooks.debugPositionMs;
  if (position == null) return null;
  final Finder layer = find.byType(VideoSubtitleMaskLayer);
  if (layer.evaluate().isEmpty) {
    return (positionMs: position, visible: false, rect: null);
  }
  final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
    find.descendant(of: layer, matching: find.byType(AnimatedOpacity)).first,
  );
  final Finder blur = find.descendant(
    of: layer,
    matching: find.byKey(const ValueKey<String>('video-subtitle-mask-blur')),
  );
  return (
    positionMs: position,
    visible: fade.opacity > 0,
    rect: blur.evaluate().isEmpty ? null : tester.getRect(blur.first),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('smart mask covers burned-in lines only while they show', (
    WidgetTester tester,
  ) async {
    if (_modelSeed.isEmpty || _fixture.isEmpty) {
      debugPrint('[smart-mask] OCR_MODEL_SEED / DESUB_FIXTURE unset: skip');
      return;
    }
    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final AppModel appModel = await readyAppModel(tester);

    // 铺进当前默认模型自己的目录（与生产同一个解析入口）。
    final Directory models = await kDefaultMangaOcrLocalModel.modelsDirectory();
    models.createSync(recursive: true);
    for (final FileSystemEntity entity in Directory(_modelSeed).listSync()) {
      if (entity is! File) continue;
      final File target = File(p.join(models.path, p.basename(entity.path)));
      if (!target.existsSync()) entity.copySync(target.path);
    }

    final VideoSubtitleMaskConfig before = appModel.videoSubtitleMask;
    try {
      await appModel.setVideoSubtitleMask(
        const VideoSubtitleMaskConfig(
          enabled: true,
          mode: VideoSubtitleMaskMode.smart,
          // 下半幅：招牌字在左上角，不在区域里。
          rect: Rect.fromLTWH(0.05, 0.6, 0.9, 0.38),
        ),
      );
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value(_kBookUid),
          title: const Value('itest smart subtitle mask'),
          videoPath: Value(File(_fixture).absolute.path),
        ),
      );
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: _kBookUid, repo: repo),
          ),
        ),
      );

      final List<_Obs> timeline = <_Obs>[];
      final Set<String> shots = <String>{};
      final Stopwatch watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 40)) {
        await tester.pump(const Duration(milliseconds: 100));
        final _Obs? o = _observe(tester);
        if (o == null) continue;
        timeline.add(o);
        for (final (String name, int at) in <(String, int)>[
          ('01-line1', 3000),
          ('02-gap', 5800),
          ('03-line2', 8500),
        ]) {
          if (!shots.contains(name) && o.positionMs >= at) {
            shots.add(name);
            await captureFlutterFrame(tester, 'smart-mask-$name');
          }
        }
        if (o.positionMs >= 11000) break;
      }
      for (final _Obs o in timeline) {
        debugPrint(
          '[smart-mask] t=${o.positionMs} visible=${o.visible} rect=${o.rect}',
        );
      }
      bool anyVisible(int from, int to) => timeline.any(
        (_Obs o) => o.positionMs >= from && o.positionMs <= to && o.visible,
      );
      bool allHidden(int from, int to) => timeline
          .where((_Obs o) => o.positionMs >= from && o.positionMs <= to)
          .every((_Obs o) => !o.visible);
      expect(timeline, isNotEmpty, reason: 'video never reported a position');
      expect(anyVisible(1500, 4000), isTrue, reason: 'line 1 not covered');
      expect(anyVisible(6500, 9500), isTrue, reason: 'line 2 not covered');
      // 第一句 4.0 s 消失 + 1.2 s 迟滞 + 一个采样周期，5.6–5.9 s 之间应已淡出。
      expect(allHidden(5600, 5900), isTrue, reason: 'mask lingers in the gap');
      expect(allHidden(10800, 11000), isTrue, reason: 'mask lingers at end');
      // 遮布只在画面下方（字幕行），不碰左上角招牌。
      final Size view = tester.view.physicalSize / tester.view.devicePixelRatio;
      for (final _Obs o in timeline) {
        final Rect? r = o.rect;
        if (!o.visible || r == null) continue;
        expect(r.top, greaterThan(view.height * 0.5), reason: 'rect=$r');
      }
    } finally {
      await appModel.setVideoSubtitleMask(before);
    }
  });
}
