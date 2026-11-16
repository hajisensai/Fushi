import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/video_frame_cover_picker.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 拍板 wb8RZZbn90「从视频画面选取封面」守卫：
/// 1. 打开先读片长，按片长 10% 取第一张预览；
/// 2. 拖动松手 / ±10 秒微调才取新预览，晚到的旧预览被丢弃；
/// 3. 「用这一帧」只在预览对上当前位置时可点，返回所选毫秒；
/// 4. 读不到片长 / 取不到帧给失败态，确认键不可点；
/// 5. 整条流程：确认后按所选时刻截**原尺寸**帧交给 apply，结束删临时目录；
/// 6. 单集菜单接上了这条入口，并经手选封面同一落盘口。

/// 1x1 PNG：真能解码，避免 Image.memory 报解码错误。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _PreviewCall {
  _PreviewCall(this.atMs, this.seq);
  final int atMs;
  final int seq;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  group('pure helpers', () {
    test('initial position is 10% of duration, clamped inside the video', () {
      expect(initialVideoFrameCoverPositionMs(600000), 60000);
      expect(initialVideoFrameCoverPositionMs(5), 1);
      expect(initialVideoFrameCoverPositionMs(1), 0);
      expect(initialVideoFrameCoverPositionMs(0), 0);
    });

    test('timestamp formats m:ss and h:mm:ss', () {
      expect(formatVideoFrameCoverTimestamp(0), '0:00');
      expect(formatVideoFrameCoverTimestamp(65000), '1:05');
      expect(formatVideoFrameCoverTimestamp(3723000), '1:02:03');
      expect(formatVideoFrameCoverTimestamp(-5), '0:00');
    });
  });

  Future<Future<int?> Function()> pumpDialog(
    WidgetTester tester, {
    required Future<int?> Function() loadDurationMs,
    required Future<Uint8List?> Function(int atMs, int seq) grabPreview,
  }) async {
    Future<int?>? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () {
                  result = showAppDialog<int>(
                    context: ctx,
                    builder: (_) => VideoFrameCoverPickerDialog(
                      loadDurationMs: loadDurationMs,
                      grabPreview: grabPreview,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result ?? Future<int?>.value();
  }

  bool confirmEnabled(WidgetTester tester) =>
      tester
          .widget<FushiFilledButton>(
            find.byKey(const ValueKey<String>('video-frame-cover-confirm')),
          )
          .onPressed !=
      null;

  testWidgets('first preview at 10%; confirm returns the previewed position', (
    WidgetTester tester,
  ) async {
    final List<_PreviewCall> calls = <_PreviewCall>[];
    final Future<int?> Function() result = await pumpDialog(
      tester,
      loadDurationMs: () async => 1200000,
      grabPreview: (int ms, int seq) async {
        calls.add(_PreviewCall(ms, seq));
        return _png;
      },
    );
    expect(calls.map((_PreviewCall c) => c.atMs), <int>[120000]);
    expect(find.text('2:00 / 20:00'), findsOneWidget);
    expect(confirmEnabled(tester), isTrue);

    // +10 秒微调：取新预览并更新时间戳。
    await tester.tap(find.byIcon(Icons.forward_10));
    await tester.pumpAndSettle();
    expect(calls.last.atMs, 130000);
    expect(find.text('2:10 / 20:00'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-frame-cover-confirm')),
    );
    await tester.pumpAndSettle();
    expect(await result(), 130000);
  });

  testWidgets('stale preview is dropped; confirm waits for the latest one', (
    WidgetTester tester,
  ) async {
    final Map<int, Completer<Uint8List?>> pending =
        <int, Completer<Uint8List?>>{};
    await pumpDialog(
      tester,
      loadDurationMs: () async => 600000,
      grabPreview: (int ms, int seq) {
        final Completer<Uint8List?> c = Completer<Uint8List?>();
        pending[ms] = c;
        return c.future;
      },
    );
    expect(pending.keys, <int>[60000]);
    pending[60000]!.complete(_png);
    await tester.pump();
    expect(confirmEnabled(tester), isTrue);

    // 连点两次 −10 秒：50s 与 40s 两个请求在途。
    await tester.tap(find.byIcon(Icons.replay_10));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.replay_10));
    await tester.pump();
    expect(pending.keys, containsAll(<int>[50000, 40000]));
    expect(confirmEnabled(tester), isFalse);

    // 最新的 40s 先回来，旧的 50s 后到：后到的旧结果不能把位置 / 预览拽回去。
    pending[40000]!.complete(_png);
    await tester.pump();
    expect(confirmEnabled(tester), isTrue);
    pending[50000]!.complete(_png);
    await tester.pump();
    expect(find.text('0:40 / 10:00'), findsOneWidget);
    expect(confirmEnabled(tester), isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('unknown duration shows the failure state, confirm disabled', (
    WidgetTester tester,
  ) async {
    int previews = 0;
    await pumpDialog(
      tester,
      loadDurationMs: () async => null,
      grabPreview: (int ms, int seq) async {
        previews++;
        return _png;
      },
    );
    expect(find.text(t.video_cover_frame_failed), findsOneWidget);
    expect(previews, 0);
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets('failed preview grab shows failure, confirm disabled', (
    WidgetTester tester,
  ) async {
    await pumpDialog(
      tester,
      loadDurationMs: () async => 600000,
      grabPreview: (int ms, int seq) async => null,
    );
    expect(find.text(t.video_cover_frame_failed), findsOneWidget);
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets(
    'flow: confirmed position is grabbed at full size and handed to apply',
    (WidgetTester tester) async {
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navKey;
      final List<({int atMs, int? scaleWidth, String outputPath})> grabs =
          <({int atMs, int? scaleWidth, String outputPath})>[];
      String? applied;
      bool appliedFileExisted = false;
      Future<bool>? done;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: Builder(
                builder: (BuildContext ctx) => TextButton(
                  onPressed: () {
                    done = pickAndApplyVideoFrameCover(
                      context: ctx,
                      videoPath: '/videos/ep01.mkv',
                      probeDurationMs: (String path) async {
                        expect(path, '/videos/ep01.mkv');
                        return 300000;
                      },
                      grabFrame:
                          ({
                            required String videoPath,
                            required int atMs,
                            required String outputPath,
                            required int? scaleWidth,
                          }) async {
                            grabs.add((
                              atMs: atMs,
                              scaleWidth: scaleWidth,
                              outputPath: outputPath,
                            ));
                            await File(outputPath).writeAsBytes(_png);
                            return outputPath;
                          },
                      apply: (String framePath) async {
                        applied = framePath;
                        appliedFileExisted = File(framePath).existsSync();
                      },
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // 临时目录与预览文件是真 IO：在真异步里放行，再推帧。
      for (int i = 0; i < 20 && grabs.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(grabs.single.atMs, 30000);
      expect(grabs.single.scaleWidth, kVideoFrameCoverPreviewWidth);
      final Directory tempDir = File(grabs.single.outputPath).parent;

      await tester.tap(
        find.byKey(const ValueKey<String>('video-frame-cover-confirm')),
      );
      await tester.pump();
      bool? ok;
      await tester.runAsync(() async {
        ok = await done;
      });
      await tester.pumpAndSettle();

      expect(ok, isTrue);
      expect(grabs.length, 2);
      expect(grabs.last.atMs, 30000);
      expect(grabs.last.scaleWidth, isNull, reason: '最终封面取原尺寸');
      expect(applied, grabs.last.outputPath);
      expect(appliedFileExisted, isTrue, reason: 'apply 时帧文件必须还在');
      expect(tempDir.existsSync(), isFalse, reason: '结束后删临时目录');
    },
  );

  test(
    'single-video menu wires the frame picker into the manual cover path',
    () {
      final String src = File(
        'lib/src/pages/implementations/home_video_page.dart',
      ).readAsStringSync();
      final int item = src.indexOf('label: t.video_cover_from_frame');
      expect(item, isNonNegative, reason: '单集菜单必须有「从视频画面选取」');
      final int pickCover = src.indexOf('label: t.srt_import_pick_cover');
      expect(pickCover, isNonNegative);
      expect(item, greaterThan(pickCover), reason: '紧跟「选择封面图片」，和设置封面放在一起');
      final int fn = src.indexOf(
        'Future<void> _pickFrameCover(VideoBookRow book)',
      );
      expect(fn, isNonNegative);
      final String body = src.substring(fn, src.indexOf('\n  }\n', fn));
      expect(body.contains('pickAndApplyVideoFrameCover('), isTrue);
      expect(
        body.contains('MediaCoverService.applyVideoCoverManual('),
        isTrue,
        reason: '必须走手选封面同一落盘口（记 manual 保护标记）',
      );
    },
  );
}
