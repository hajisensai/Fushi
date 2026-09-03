import 'dart:io';

import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_badges.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_panel.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';

/// 规格 UI：角标条、紧凑摘要行、完整规格面板。
///
/// 探测入口注入，但**文件是真的**——service 的失效判据要读真实 FileStat。
void main() {
  late Directory tempDir;
  late FushiDatabase db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_specs_widgets');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String writeFile(String name) {
    final File file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(List<int>.filled(64, 0));
    return file.path;
  }

  const VideoProbeFacts hdr4k = VideoProbeFacts(
    containerBitrate: 15586453,
    video: VideoStreamFacts(
      codec: 'hevc',
      width: 3840,
      height: 2160,
      pixelFormat: 'yuv420p10le',
      bitDepth: 10,
      frameRateMilli: 23976,
      colorPrimaries: 'bt2020',
      colorTransfer: 'smpte2084',
    ),
    audioTracks: <AudioTrackFacts>[
      AudioTrackFacts(
        index: 1,
        codec: 'flac',
        channels: 6,
        channelLayout: '5.1',
        language: 'jpn',
        title: '日本語',
        isDefault: true,
      ),
      AudioTrackFacts(
        index: 2,
        codec: 'aac',
        channels: 2,
        channelLayout: 'stereo',
        language: 'eng',
        isCommentary: true,
      ),
    ],
    subtitleTracks: <SubtitleTrackFacts>[
      SubtitleTrackFacts(
        index: 3,
        codec: 'subrip',
        language: 'chi',
        isDefault: true,
      ),
    ],
  );

  /// 建一个已经探好某个文件的 service。
  ///
  /// **必须包在 `tester.runAsync` 里**：`testWidgets` 的 body 跑在 fake-async zone,
  /// 里面 await 真实 IO（这里是 FileStat + sqlite 写入）永远不会完成，测试直接挂死。
  /// 预置缓存又只能走真实 IO——service 的失效判据读的就是真实 FileStat。
  Future<VideoSpecsService> serviceWith(
    WidgetTester tester,
    String path,
    VideoProbeFacts facts,
  ) async {
    final VideoSpecsService service =
        VideoSpecsService(db, probe: (String p) async => facts);
    await tester.runAsync(() => service.resolve(path));
    return service;
  }

  Future<void> pumpWith(
    WidgetTester tester,
    VideoSpecsService service,
    Widget child,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        // 不额外 addTearDown(service.dispose)：ChangeNotifierProvider 在 scope
        // 销毁时会自己 dispose 这个 notifier，再 dispose 一次会触发
        // 「A ChangeNotifier was used after being disposed」断言。
        overrides: <Override>[
          videoSpecsProvider.overrideWith((Ref ref) => service),
        ],
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      ),
    );
    await tester.pump();
  }

  group('封面角标条', () {
    testWidgets('4K HDR10 渲染成两个胶囊', (WidgetTester tester) async {
      final String path = writeFile('a.mkv');
      final VideoSpecsService service = await serviceWith(tester, path, hdr4k);

      await pumpWith(tester, service, VideoSpecsBadgeStrip(filePath: path));

      expect(find.text('4K'), findsOneWidget);
      expect(find.text('HDR10'), findsOneWidget);
    });

    testWidgets('SDR 只出清晰度', (WidgetTester tester) async {
      final String path = writeFile('b.mkv');
      final VideoSpecsService service = await serviceWith(
        tester,
        path,
        const VideoProbeFacts(
          video: VideoStreamFacts(
            width: 1920,
            height: 1080,
            colorPrimaries: 'bt709',
            colorTransfer: 'bt709',
          ),
        ),
      );

      await pumpWith(tester, service, VideoSpecsBadgeStrip(filePath: path));

      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('SDR'), findsNothing);
      expect(find.text('HDR10'), findsNothing);
    });

    testWidgets('规格未知时整个不占位', (WidgetTester tester) async {
      final String path = writeFile('c.mkv');
      final VideoSpecsService service =
          await serviceWith(tester, path, VideoProbeFacts.empty);

      await pumpWith(tester, service, VideoSpecsBadgeStrip(filePath: path));

      // 没有任何文字，且自身尺寸为零——卡片布局一格不该被撑开。
      expect(find.byType(Text), findsNothing);
      expect(
        tester.getSize(find.byType(VideoSpecsBadgeStrip)),
        Size.zero,
      );
    });

    testWidgets('流 URL 不探也不显示', (WidgetTester tester) async {
      int probeCalls = 0;
      final VideoSpecsService service = VideoSpecsService(
        db,
        probe: (String p) async {
          probeCalls++;
          return hdr4k;
        },
      );
      // 不 addTearDown(dispose)：ProviderScope 销毁时已经 dispose 过一次。

      await pumpWith(
        tester,
        service,
        const VideoSpecsBadgeStrip(
          filePath: 'https://example.com/stream.m3u8',
        ),
      );

      expect(probeCalls, 0, reason: '滚动列表不该对远端条目发起网络请求');
      expect(find.byType(Text), findsNothing);
    });
  });

  group('紧凑摘要行', () {
    testWidgets('清晰度 · 动态范围 · 编码 一行', (WidgetTester tester) async {
      final String path = writeFile('d.mkv');
      final VideoSpecsService service = await serviceWith(tester, path, hdr4k);

      await pumpWith(tester, service, VideoSpecsInlineLine(filePath: path));

      expect(find.text('4K · HDR10 · HEVC'), findsOneWidget);
    });

    testWidgets('未探到时不占位（集卡高度钳死，多一行会顶掉简介）',
        (WidgetTester tester) async {
      final String path = writeFile('e.mkv');
      final VideoSpecsService service =
          await serviceWith(tester, path, VideoProbeFacts.empty);

      await pumpWith(tester, service, VideoSpecsInlineLine(filePath: path));

      expect(tester.getSize(find.byType(VideoSpecsInlineLine)), Size.zero);
    });
  });

  group('完整规格面板', () {
    testWidgets('摊开分辨率/动态范围/编码/色深/帧率/码率', (WidgetTester tester) async {
      final String path = writeFile('f.mkv');
      final VideoSpecsService service = await serviceWith(tester, path, hdr4k);

      await pumpWith(tester, service, VideoSpecsPanel(filePath: path));

      expect(find.text('4K (3840×2160)'), findsOneWidget);
      expect(find.text('HDR10'), findsOneWidget);
      expect(find.text('HEVC'), findsOneWidget);
      expect(find.text('10 bit'), findsOneWidget);
      expect(find.text('23.976 fps'), findsOneWidget);
      expect(find.text('16 Mbps'), findsOneWidget);
    });

    testWidgets('音轨逐条列出，含默认/评论标志', (WidgetTester tester) async {
      final String path = writeFile('g.mkv');
      final VideoSpecsService service = await serviceWith(tester, path, hdr4k);

      await pumpWith(tester, service, VideoSpecsPanel(filePath: path));

      expect(find.textContaining('日本語 · FLAC · 5.1'), findsOneWidget);
      expect(find.textContaining('ENG · AAC · 2.0'), findsOneWidget);
      // 标志位跟在名字后面。断言「带左括号」而不是断言具体文案：标志词来自 i18n，
      // 测试不该钉死在某个语言的值上。
      expect(
        find.textContaining('日本語 · FLAC · 5.1（'),
        findsOneWidget,
        reason: '默认轨应带标志位后缀',
      );
      expect(
        find.textContaining('ENG · AAC · 2.0（'),
        findsOneWidget,
        reason: '评论轨应带标志位后缀',
      );
    });

    testWidgets('字幕轨列出', (WidgetTester tester) async {
      final String path = writeFile('h.mkv');
      final VideoSpecsService service = await serviceWith(tester, path, hdr4k);

      await pumpWith(tester, service, VideoSpecsPanel(filePath: path));

      expect(find.textContaining('CHI · SRT'), findsOneWidget);
    });

    testWidgets('规格未探到时整块不渲染', (WidgetTester tester) async {
      final String path = writeFile('i.mkv');
      final VideoSpecsService service =
          await serviceWith(tester, path, VideoProbeFacts.empty);

      await pumpWith(tester, service, VideoSpecsPanel(filePath: path));

      expect(tester.getSize(find.byType(VideoSpecsPanel)), Size.zero);
    });
  });
}
