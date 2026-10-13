import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/diagnostics/video_diag_log.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'test_helpers.dart';

/// BUG-3315 真机 E2E：Windows 上 H.264 High 10（D3D11VA 无此解码配置）在**真实 app
/// 进程**里走 `nvdec-copy` 硬解，且整段播放不崩、不掉帧。
///
/// BUG-1639 的教训是「libmpv 独立进程不崩 ≠ app 进程不崩」，所以 CUDA 路径必须在 app
/// 里起播验证。证据走诊断时间轴（`mpv/stats` 的 params 行与每秒快照），同时验证诊断
/// 默认过滤串真的能采到掉帧统计。
///
/// 片源经环境变量给出（需要真实的 H.264 High 10 文件，仓库不带）；未给出时跳过：
///   $env:FUSHI_HWDEC_ITEST_VIDEO = 'D:\video\...\S01E06.mkv'
///   powershell -File fushi/tool/run_windows_itest.ps1 `
///     -Target integration_test/video_hwdec_hi10p_itest.dart
const String _kBookUid = 'video/itest-hwdec-hi10p';
const Duration _kPlayFor = Duration(seconds: 20);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final String? videoPath = Platform.environment['FUSHI_HWDEC_ITEST_VIDEO'];

  testWidgets(
    'H.264 High 10 plays on nvdec-copy in the app process without drops',
    (WidgetTester tester) async {
      app.main(const <String>[]);
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      VideoDiagLog.instance.applyMsgLevel(VideoDiagLog.defaultMsgLevel);
      await VideoDiagLog.instance.setEnabled(true);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value(_kBookUid),
          title: const Value('hwdec hi10p probe'),
          videoPath: Value(File(videoPath!).absolute.path),
          lastPositionMs: const Value(60000),
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

      VideoFushiTestHooks? readHooks() {
        if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
            as VideoFushiTestHooks;
      }

      bool ready = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (readHooks()?.debugPositionMs != null) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: '控制器应在 load 后就绪');
      if (readHooks()?.debugIsPlaying != true) await readHooks()!.debugPlay();

      final int startPos = readHooks()!.debugPositionMs ?? 0;
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < _kPlayFor) {
        await tester.pump(const Duration(milliseconds: 125));
      }
      final int endPos = readHooks()!.debugPositionMs ?? 0;

      final List<String> stats = VideoDiagLog.instance.lines
          .where((String l) => l.contains('[mpv/stats]'))
          .toList();
      for (final String l in stats) {
        debugPrint('[hwdec-itest] $l');
      }
      debugPrint(
        '[hwdec-itest] advanced ${endPos - startPos}ms '
        'in ${sw.elapsedMilliseconds}ms',
      );

      final List<String> params = stats
          .where((String l) => l.contains(' params '))
          .toList();
      expect(
        params,
        isNotEmpty,
        reason: '默认过滤串下诊断必须采到 mpv/stats（BUG-3315 前一行都没有）',
      );
      expect(
        params.last,
        contains('hwdec=nvdec-copy'),
        reason: 'H.264 High 10 应由 nvdec-copy 硬解，而不是回落软解',
      );
      expect(
        endPos - startPos,
        greaterThan(_kPlayFor.inMilliseconds - 3000),
        reason: '播放应持续推进（进程存活、未卡死）',
      );

      int dropped = 0;
      final RegExp drop = RegExp(r'(?:vo-drop|dec-drop)=\+(\d+)');
      for (final String l in stats.where(
        (String l) => l.contains('playing=true'),
      )) {
        for (final RegExpMatch m in drop.allMatches(l)) {
          dropped += int.parse(m.group(1)!);
        }
      }
      debugPrint('[hwdec-itest] dropped frames while playing: $dropped');
      expect(dropped, 0, reason: '硬解后 1080p Hi10P 播放不应掉帧');

      await readHooks()!.debugPause();
      await navigator.maybePop();
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
      }
      await VideoDiagLog.instance.setEnabled(false);
    },
    skip: videoPath == null || !Platform.isWindows,
  );
}
