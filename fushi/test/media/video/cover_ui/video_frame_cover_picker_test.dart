import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/video_frame_cover_picker.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 拍板 wb8RZZbn90「从视频画面选取封面」守卫：
/// 1. 打开先读片长，按片长 10% 取第一张预览；
/// 2. 拖动松手 / ±10 秒微调才取新预览；取帧单飞，连点只取最后一次位置；
/// 3. 「用这一帧」只在预览对上当前位置时可点，返回所选毫秒；
/// 4. 读不到片长 / 取不到帧给失败态，确认键不可点；
/// 5. 确认后按所选时刻截**原尺寸**帧交给 apply，结束删临时目录（IO 段纯 test 验）；
/// 单集菜单入口与落盘接线的行为测试在 test/pages/home_video_page_menu_test.dart。

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
    // 预览可能故意挂着（转圈不停），不能 pumpAndSettle：推过弹窗进场动画即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
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
    await tester.tap(find.byIcon(FushiIcons.forward10));
    await tester.pumpAndSettle();
    expect(calls.last.atMs, 130000);
    expect(find.text('2:10 / 20:00'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-frame-cover-confirm')),
    );
    await tester.pumpAndSettle();
    expect(await result(), 130000);
  });

  testWidgets('one grab in flight; rapid seeks collapse to the last position', (
    WidgetTester tester,
  ) async {
    // 连点 ±10 秒曾每次都新起一个 ffmpeg（N 路并发解码），旧结果回来后才丢。
    // 现在单飞：在途期间的选择只记最后一次，中间值不发请求。
    final List<int> requested = <int>[];
    final Map<int, Completer<Uint8List?>> pending =
        <int, Completer<Uint8List?>>{};
    int inFlight = 0;
    int maxInFlight = 0;
    await pumpDialog(
      tester,
      loadDurationMs: () async => 600000,
      grabPreview: (int ms, int seq) async {
        requested.add(ms);
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        final Completer<Uint8List?> c = Completer<Uint8List?>();
        pending[ms] = c;
        try {
          return await c.future;
        } finally {
          inFlight--;
        }
      },
    );
    expect(requested, <int>[60000]);

    // 首张预览还在途时连点 5 次 −10 秒：一个新请求都不起。
    for (int i = 0; i < 5; i++) {
      await tester.tap(find.byIcon(FushiIcons.replay10));
      await tester.pump();
    }
    expect(requested, <int>[60000]);
    expect(find.text('0:10 / 10:00'), findsOneWidget);
    expect(confirmEnabled(tester), isFalse);

    // 在途的 60s 回来：结果作废，直接改取最后一次的 10s，中间 50/40/30/20s 全丢。
    pending[60000]!.complete(_png);
    await tester.pump();
    expect(requested, <int>[60000, 10000]);
    expect(confirmEnabled(tester), isFalse, reason: '过期的 60s 预览不能放行确认');

    pending[10000]!.complete(_png);
    await tester.pump();
    expect(confirmEnabled(tester), isTrue);
    expect(find.text('0:10 / 10:00'), findsOneWidget);
    expect(maxInFlight, 1, reason: '同一时刻最多一个预览取帧在途');
    await tester.pumpAndSettle();
  });

  testWidgets('seeking back to the in-flight position reuses its result', (
    WidgetTester tester,
  ) async {
    final List<int> requested = <int>[];
    final Map<int, Completer<Uint8List?>> pending =
        <int, Completer<Uint8List?>>{};
    await pumpDialog(
      tester,
      loadDurationMs: () async => 600000,
      grabPreview: (int ms, int seq) {
        requested.add(ms);
        final Completer<Uint8List?> c = Completer<Uint8List?>();
        pending[ms] = c;
        return c.future;
      },
    );
    // 60s 在途时 −10 再 +10：最后一次选择就是在途的位置，不再重取。
    await tester.tap(find.byIcon(FushiIcons.replay10));
    await tester.pump();
    await tester.tap(find.byIcon(FushiIcons.forward10));
    await tester.pump();
    pending[60000]!.complete(_png);
    await tester.pump();
    expect(requested, <int>[60000]);
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

  group('applyVideoFrameCoverAt', () {
    test('grabs the confirmed time at full size, applies, cleans up', () async {
      final List<({int atMs, int? scaleWidth, String outputPath})> grabs =
          <({int atMs, int? scaleWidth, String outputPath})>[];
      String? applied;
      bool existedDuringApply = false;
      final bool ok = await applyVideoFrameCoverAt(
        videoPath: '/videos/ep01.mkv',
        atMs: 30000,
        grabFrame:
            ({
              required String videoPath,
              required int atMs,
              required String outputPath,
              required int? scaleWidth,
            }) async {
              expect(videoPath, '/videos/ep01.mkv');
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
          existedDuringApply = File(framePath).existsSync();
        },
      );
      expect(ok, isTrue);
      expect(grabs.single.atMs, 30000);
      expect(grabs.single.scaleWidth, isNull, reason: '最终封面取原尺寸');
      expect(applied, grabs.single.outputPath);
      expect(existedDuringApply, isTrue, reason: 'apply 时帧文件必须还在');
      expect(
        File(grabs.single.outputPath).parent.existsSync(),
        isFalse,
        reason: '结束后删临时目录',
      );
    });

    test('no frame: false, apply never called, temp dir removed', () async {
      String? requested;
      bool applyCalled = false;
      final bool ok = await applyVideoFrameCoverAt(
        videoPath: '/videos/ep01.mkv',
        atMs: 1000,
        grabFrame:
            ({
              required String videoPath,
              required int atMs,
              required String outputPath,
              required int? scaleWidth,
            }) async {
              requested = outputPath;
              return null;
            },
        apply: (String framePath) async => applyCalled = true,
      );
      expect(ok, isFalse);
      expect(applyCalled, isFalse);
      expect(requested, isNotNull);
      expect(File(requested!).parent.existsSync(), isFalse);
    });
  });

  group('isVideoFrameCoverPickableSource', () {
    test('local media file is pickable', () {
      expect(isVideoFrameCoverPickableSource('D:/v/ep01.mkv'), isTrue);
      expect(
        isVideoFrameCoverPickableSource('D:/Disc/BDMV/PLAYLIST/00001.mpls'),
        isTrue,
      );
    });

    test('blu-ray episode virtual path is not pickable', () {
      expect(
        isVideoFrameCoverPickableSource('D:/Disc/BDMV/PLAYLIST/00001.p03.mpls'),
        isFalse,
      );
    });

    test('stream / strm / playlist manifest are not pickable', () {
      expect(isVideoFrameCoverPickableSource(''), isFalse);
      expect(isVideoFrameCoverPickableSource('https://x/y.mp4'), isFalse);
      expect(isVideoFrameCoverPickableSource('D:/v/a.strm'), isFalse);
      expect(isVideoFrameCoverPickableSource('D:/v/list.m3u8'), isFalse);
    });
  });

  group('grabVideoFramePreviewBytes', () {
    test('reads the preview bytes and deletes the preview file', () async {
      final Directory dir = await Directory.systemTemp.createTemp('pr3612_a_');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      String? written;
      final Uint8List? bytes = await grabVideoFramePreviewBytes(
        videoPath: 'v.mkv',
        atMs: 1000,
        seq: 1,
        tempDir: dir,
        isClosed: () => false,
        grabFrame:
            ({
              required String videoPath,
              required int atMs,
              required String outputPath,
              required int? scaleWidth,
            }) async {
              File(outputPath).writeAsBytesSync(_png);
              written = outputPath;
              return outputPath;
            },
      );
      expect(bytes, _png);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File(written!).existsSync(), isFalse);
      expect(dir.existsSync(), isTrue);
    });

    test(
      'grab finishing after the dialog closed removes the temp dir',
      () async {
        final Directory dir = await Directory.systemTemp.createTemp(
          'pr3612_b_',
        );
        addTearDown(() async {
          if (dir.existsSync()) await dir.delete(recursive: true);
        });
        bool closed = false;
        final Uint8List? bytes = await grabVideoFramePreviewBytes(
          videoPath: 'v.mkv',
          atMs: 1000,
          seq: 2,
          tempDir: dir,
          isClosed: () => closed,
          grabFrame:
              ({
                required String videoPath,
                required int atMs,
                required String outputPath,
                required int? scaleWidth,
              }) async {
                // 弹窗关闭：目录被删；在途的抽帧随后又把目录建出来写了预览。
                closed = true;
                dir.deleteSync(recursive: true);
                File(outputPath).parent.createSync(recursive: true);
                File(outputPath).writeAsBytesSync(_png);
                return outputPath;
              },
        );
        expect(bytes, isNull);
        expect(dir.existsSync(), isFalse);
      },
    );
  });
}
