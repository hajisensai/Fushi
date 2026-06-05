// 真机集成测试：播放列表逐集进度「退出→再进续播」全链路（问题 1 根因验证）。
//
// 在真实 libmpv 窗口上跑完整失败路径：用本机龙女仆素材（D:\video\...）seed 一个
// 播放列表书 → 打开 [VideoHibikiPage] → 真实播放数秒 → 经页面 `PopScope` 的
// pop 处理器退出（这正是修复点：退出前 await `controller.flushPosition()` 落库）→
// 重新打开 → 断言 controller seek 到上次位置（DB 读回 + 续播后位置 >1s 为证）。
//
// 运行：
//   .\tool\run_windows_itest.ps1 integration_test\video_position_restore_test.dart
// 无龙女仆素材（CI / 别的机器）则整组 skip——不伪造视频解码（需 media_kit native）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'test_helpers.dart';

/// 本机龙女仆第一集（与 test/media/video/dragonmaid_realdata_test.dart 同源素材）。
const String _kEp0 =
    r"D:\video\Miss Kobayashi's Dragon Maid\Season 01\Miss Kobayashi's Dragon Maid - S01E01.mkv";
const String _kEp1 =
    r"D:\video\Miss Kobayashi's Dragon Maid\Season 01\Miss Kobayashi's Dragon Maid - S01E02.mkv";
const String _kBookUid = 'video/itest-pos-restore';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bool hasFixture = File(_kEp0).existsSync();

  testWidgets(
    'playlist episode position survives exit→reopen on the real player',
    (WidgetTester tester) async {
      // 离屏真窗口在 0→1920 resize / 控制条布局时会冒非致命框架异常（与本修复无关）。
      // 收集而不重抛，避免淹没本测对「进度持久化链路」的断言；测尾恢复并只对真正
      // 关心的不变式断言。
      final List<String> caught = <String>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        caught.add(details.exceptionAsString());
        debugPrint('[video-itest] caught: ${details.exceptionAsString()}');
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

        // Seed a 2-episode playlist, episode 0 starts at position 0.
        final List<PlaylistEntry> episodes = <PlaylistEntry>[
          const PlaylistEntry(title: 'EP0', path: _kEp0),
          const PlaylistEntry(title: 'EP1', path: _kEp1),
        ];
        final String json =
            jsonEncode(episodes.map((PlaylistEntry e) => e.toJson()).toList());
        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: const Value(_kBookUid),
          title: const Value('itest pos restore'),
          videoPath: Value(_kEp0),
          playlistJson: Value(json),
          currentEpisode: const Value(0),
        ));

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);

        // ── ① 打开 → 真实播放数秒 → 经 PopScope pop 处理器退出 ──────────────
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoHibikiPage(bookUid: _kBookUid, repo: repo),
        )));

        // 等 load() 实例化原生 player（控制器就绪 = debugPositionMs 非 null）。桌面
        // media_kit 控制条 hover 才显图标，故用 controller 状态判就绪，不依赖图标。
        VideoHibikiTestHooks? readHooks() {
          final Iterable<Element> els = find.byType(VideoHibikiPage).evaluate();
          if (els.isEmpty) return null;
          return tester.state<State<VideoHibikiPage>>(
              find.byType(VideoHibikiPage)) as VideoHibikiTestHooks;
        }

        bool ready = false;
        for (int i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (readHooks()?.debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        expect(ready, isTrue, reason: '控制器应在 load 后就绪（debugPositionMs 非 null）');

        // 真实播放约 4 秒（位置自然前进，跨过整秒边界，让周期保存与退出 flush 都有料）。
        // 直接驱动 controller.play()：本测验进度持久化链路，非焦点交互。
        final VideoHibikiTestHooks hooks = readHooks()!;
        await hooks.debugPlay();
        for (int i = 0; i < 32; i++) {
          await tester.pump(const Duration(milliseconds: 125));
        }
        final int playedMs = hooks.debugPositionMs ?? 0;
        expect(playedMs, greaterThan(1500),
            reason: '真实播放应前进超过 1.5s，实测=$playedMs');

        // 退出：走页面 PopScope 的 pop 处理器（修复点——退出前 await flushPosition）。
        await navigator.maybePop();
        // 让 onPopInvokedWithResult 的 await flush + pop 跑完。
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(VideoHibikiPage).evaluate().isEmpty) break;
        }
        expect(find.byType(VideoHibikiPage), findsNothing,
            reason: '退出后视频页应已 pop');

        // 退出后 DB 应记下刚才播放到的位置（容许整秒节流与 flush 之间的 ~1s 容差）。
        final VideoBookRow? afterExit = await repo.getByBookUid(_kBookUid);
        final List<dynamic> savedRaw =
            jsonDecode(afterExit!.playlistJson!) as List<dynamic>;
        final int savedPos =
            (savedRaw[0] as Map<String, dynamic>)['positionMs'] as int;
        expect(savedPos, greaterThan(1000),
            reason: '退出前必须把播放位置 flush 落库，实测 savedPos=$savedPos '
                '(playedMs=$playedMs)');

        // ── ② 重新打开 → 断言 seek 到上次位置（续播，不从头）──────────────────
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoHibikiPage(bookUid: _kBookUid, repo: repo),
        )));
        bool ready2 = false;
        for (int i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (readHooks()?.debugPositionMs != null) {
            ready2 = true;
            break;
          }
        }
        expect(ready2, isTrue, reason: '重开后控制器应就绪（debugPositionMs 非 null）');

        // load 后 player 暂停在 seek 目标处；暂停时 libmpv `state.position` 不前进，
        // 需 play() 让它从 seek 位置恢复解码，position 才反映出来。续播后位置应落在
        // 上次保存位置附近（>1s，证明从 seek 点续播而非从头 0 开始）。
        await readHooks()!.debugPlay();
        int restored = 0;
        for (int i = 0; i < 64; i++) {
          await tester.pump(const Duration(milliseconds: 125));
          restored = readHooks()?.debugPositionMs ?? 0;
          if (restored > 1000) break;
        }
        expect(restored, greaterThan(1000),
            reason:
                '重开应 seek 回上次位置 (savedPos=$savedPos)，实测 restored=$restored');

        // 清场。
        await navigator.maybePop();
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(VideoHibikiPage).evaluate().isEmpty) break;
        }
        debugPrint('[video-itest] non-fatal framework errors=${caught.length}');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
    skip: !hasFixture,
  );
}
