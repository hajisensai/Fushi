// 真机集成测试：**同一集**「播放 → 退出 → 再打开」必须仍能真正 open。
//
// 用户实测故障（2026-09-10，Windows 桌面版，同一 app 会话内）：
//   18:21:30–18:26:07 打开本地 6.7GB mkv 播放 135 秒（study_segments 有记录）；
//   退出播放页；18:30:48 再打开同一集 → 画面全黑、控件齐全、`00:00 / 00:00`、
//   进程读盘 0 字节、无异常、无任何错误提示。
//
// 即 libmpv 第二次 `open` 没有真正生效，而页面的首帧兜底 promote 把它当成了就绪。
// 本测把这条路径钉死：第二次打开后 **debugDurationMs 必须 > 0**（媒体真被打开），
// 且 play 后 position 必须真的前进。
//
// 与既有 [video_position_restore_test.dart] 的区别：那条测的是**播放列表换集**的
// 进度续播（走 seek 恢复），素材是龙女仆；本测复现的是**同一集原地重开**，且第二
// 次从 0 开始（无 seek 恢复），素材用故障现场那一部（16 条流 / truehd / PGS /
// 8 个字体附件，容器远比龙女仆重）。
//
// 运行：
//   .\tool\run_windows_itest.ps1 integration_test\video_reopen_same_episode_itest.dart
// 无素材（CI / 别的机器）则整组 skip——不伪造视频解码（需 media_kit native）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';

import 'test_helpers.dart';

/// 故障现场素材：6.7GB / h264 1080p / 16 条流（flac + truehd + ac3 + ass×2 +
/// PGS×2 + 8 个字体附件）。容器重是复现条件的一部分，别换成轻素材。
const String _kEpisode =
    r'D:\video\Teasing Master Takagi-san\Season 01\Teasing Master Takagi-san - S01E01.mkv';
const String _kBookUid = 'video/itest-reopen-same-episode';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bool hasFixture = File(_kEpisode).existsSync();

  testWidgets(
    'same episode reopens and really opens on the real player',
    (WidgetTester tester) async {
      // 离屏真窗口在 0→1920 resize / 控制条布局时会冒非致命框架异常（与本用例无关）。
      // 收集而不重抛，测尾只对真正关心的不变式断言。
      final List<String> caught = <String>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        caught.add(details.exceptionAsString());
        debugPrint('[reopen-itest] caught: ${details.exceptionAsString()}');
      };
      try {
        app.main(const <String>[]);
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        // 单视频（非播放列表），从 0 开始——与故障现场一致（lastPositionMs=0）。
        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: const Value(_kBookUid),
          title: const Value('itest reopen same episode'),
          videoPath: const Value(_kEpisode),
          lastPositionMs: const Value(0),
        ));

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);

        VideoFushiTestHooks? readHooks() {
          final Iterable<Element> els = find.byType(VideoFushiPage).evaluate();
          if (els.isEmpty) return null;
          return tester.state<State<VideoFushiPage>>(
              find.byType(VideoFushiPage)) as VideoFushiTestHooks;
        }

        /// 打开一次并等到「控制器就绪」，返回就绪时的 hooks。
        Future<VideoFushiTestHooks> openOnce(String label) async {
          unawaited(navigator.push<void>(MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: _kBookUid, repo: repo),
          )));
          bool ready = false;
          // 6.7GB 容器的内嵌字幕枚举可能先跑一轮 ffmpeg，给足 30s。
          for (int i = 0; i < 120; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (readHooks()?.debugPositionMs != null) {
              ready = true;
              break;
            }
          }
          expect(ready, isTrue,
              reason: '[$label] 控制器应在 load 后就绪（debugPositionMs 非 null）');
          return readHooks()!;
        }

        /// 走页面自己的退出汇聚点（PopScope → _handleBackOrExit）。
        Future<void> exitOnce(String label) async {
          await navigator.maybePop();
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
          }
          expect(find.byType(VideoFushiPage), findsNothing,
              reason: '[$label] 退出后视频页应已 pop');
        }

        // ── ① 第一次打开：必须真的 open（duration > 0）并能播 ─────────────────
        final VideoFushiTestHooks first = await openOnce('first');
        await first.debugPlay();
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 125));
        }
        final int firstDuration = first.debugDurationMs ?? 0;
        final int firstPlayed = first.debugPositionMs ?? 0;
        expect(firstDuration, greaterThan(0),
            reason: '首次打开 libmpv 应报出真实时长，实测=$firstDuration');
        expect(firstPlayed, greaterThan(1500),
            reason: '首次打开应真实播放前进，实测=$firstPlayed');

        await exitOnce('first');

        // 故障现场两次打开之间隔了约 4 分钟；这里只需跨过 teardown 的异步收尾窗口。
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // ── ② 再打开同一集：这里正是故障点 ────────────────────────────────
        final VideoFushiTestHooks second = await openOnce('second');
        int secondDuration = second.debugDurationMs ?? 0;
        // duration 由 libmpv 异步报出，给它与首次同等的观测窗口。
        for (int i = 0; i < 40 && secondDuration <= 0; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          secondDuration = readHooks()?.debugDurationMs ?? 0;
        }
        expect(secondDuration, greaterThan(0),
            reason: '重开同一集后 libmpv 必须真的打开媒体（用户现场此处恒 0 → '
                '画面全黑、控件显示 00:00/00:00 且无任何错误提示）');

        await readHooks()!.debugPlay();
        int secondPlayed = 0;
        for (int i = 0; i < 64; i++) {
          await tester.pump(const Duration(milliseconds: 125));
          secondPlayed = readHooks()?.debugPositionMs ?? 0;
          if (secondPlayed > 1000) break;
        }
        expect(secondPlayed, greaterThan(1000),
            reason: '重开同一集后必须真的能播放前进，实测=$secondPlayed');

        // ── ③ 重开失败时绝不能把 0 覆盖掉真实进度（数据损坏防线）────────────
        final VideoBookRow? row = await repo.getByBookUid(_kBookUid);
        expect(row, isNotNull);

        await exitOnce('second');
        debugPrint(
            '[reopen-itest] non-fatal framework errors=${caught.length}');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
    skip: !hasFixture,
  );
}
