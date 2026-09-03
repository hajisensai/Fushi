import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

/// 播放页「找字幕」必须与下载管线走**同一套** [VideoSubtitleRegistry]。
///
/// 此前对话框自建 JimakuClient 直连 Jimaku，下载管线走 registry（Jimaku +
/// OpenSubtitles）——同一个「找字幕」在两个入口能力不同，播放页永远搜不到
/// OpenSubtitles。这条测试就是那个能力差的行为门。
void main() {
  Widget host({
    required VideoSubtitleRegistry registry,
    required String saveDirectory,
    String apiKey = 'jimaku-key',
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: JimakuSubtitleDialog(
              initialQuery: 'Some Anime',
              initialApiKey: apiKey,
              onApiKeyChanged: (String _) async {},
              saveDirectory: saveDirectory,
              subtitleRegistry: () => registry,
              // AniList 恒空 → 走文本回退路径，不触网。
              httpClientFactory: () async => http_testing.MockClient(
                (http.Request request) async => http.Response(
                  jsonEncode(<String, Object?>{
                    'data': <String, Object?>{
                      'Page': <String, Object?>{'media': <Object?>[]},
                    },
                  }),
                  200,
                  headers: <String, String>{
                    'content-type': 'application/json; charset=utf-8',
                  },
                ),
              ),
            ),
          ),
        ),
      );

  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('播放页找字幕列出全部已配置来源的候选（Jimaku + OpenSubtitles）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final VideoSubtitleRegistry registry =
        VideoSubtitleRegistry(<VideoSubtitleProvider>[
      _FakeSubtitleProvider(
        id: 'jimaku',
        priority: 100,
        fileName: 'from.jimaku.ep01.ja.srt',
        releaseName: 'Jimaku Entry',
        language: 'ja',
      ),
      _FakeSubtitleProvider(
        id: 'opensubtitles',
        priority: 200,
        fileName: 'from.opensubtitles.ep01.en.srt',
        releaseName: 'OpenSubtitles Release',
        language: 'en',
      ),
    ]);

    await tester.pumpWidget(host(
      registry: registry,
      saveDirectory: Directory.systemTemp.createTempSync('fushi_subs').path,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(find.text('from.jimaku.ep01.ja.srt'), findsOneWidget);
    expect(
      find.text('from.opensubtitles.ep01.en.srt'),
      findsOneWidget,
      reason: '播放页此前只搜 Jimaku，OpenSubtitles 的候选结构上出不来',
    );
  });

  testWidgets('只配了 OpenSubtitles（Jimaku key 为空）也能搜，不再被 Jimaku key 卡住',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final VideoSubtitleRegistry registry =
        VideoSubtitleRegistry(<VideoSubtitleProvider>[
      _FakeSubtitleProvider(
        id: 'opensubtitles',
        priority: 200,
        fileName: 'only.opensubtitles.ep01.en.srt',
        releaseName: 'OpenSubtitles Release',
        language: 'en',
      ),
    ]);

    await tester.pumpWidget(host(
      registry: registry,
      saveDirectory: Directory.systemTemp.createTempSync('fushi_subs2').path,
      apiKey: '',
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(find.text(t.video_jimaku_no_key), findsNothing,
        reason: '门槛是「有没有可用来源」，不是「有没有 Jimaku key」');
    expect(find.text('only.opensubtitles.ep01.en.srt'), findsOneWidget);
  });

  // 正文语言探测是靠 download 实现的，而 OpenSubtitles 的 /download 就是计配额那一步
  // （响应带 remaining，免费账号一天 5~20 次）。判据必须落在「provider 有没有配额」
  // 上，不能用「候选 language 字段是不是空的」代替 —— 后者与配额毫无关系，而
  // OpenSubtitles 恰恰经常不给 language，最该保护的源反而最常被探测。
  testWidgets('有下载配额的源：语言为空也不得被探测（零 download）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _FakeSubtitleProvider metered = _FakeSubtitleProvider(
      id: 'opensubtitles',
      priority: 200,
      fileName: 'metered.ep01.srt',
      releaseName: 'Metered Release',
      language: '', // 空语言：旧实现正是靠这个条件决定要不要探测
      allowsFreeProbeDownload: false,
    );

    await tester.pumpWidget(host(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[metered]),
      saveDirectory: Directory.systemTemp.createTempSync('fushi_probe1').path,
      apiKey: '',
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(metered.downloadCalls, 0, reason: '为一个展示标签白烧用户的每日下载配额，失败还被静默吞掉');
  });

  testWidgets('无配额的源：语言为空时才做探测', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _FakeSubtitleProvider free = _FakeSubtitleProvider(
      id: 'jimaku',
      priority: 100,
      fileName: 'free.ep01.srt',
      releaseName: 'Free Release',
      language: '',
      allowsFreeProbeDownload: true,
    );

    await tester.pumpWidget(host(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[free]),
      saveDirectory: Directory.systemTemp.createTempSync('fushi_probe2').path,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.video_jimaku_search));
    await tester.pumpAndSettle();

    expect(free.downloadCalls, greaterThan(0),
        reason: '无配额的源仍应探测，否则门控写成了「一律不探」');
  });
}

class _FakeSubtitleProvider implements VideoSubtitleProvider {
  _FakeSubtitleProvider({
    required this.id,
    required this.priority,
    required this.fileName,
    required this.releaseName,
    required this.language,
    this.allowsFreeProbeDownload = false,
  });

  /// 探测许可可配：本测试要区分「有配额的源不许被探测」与「无配额的源才探」。
  @override
  final bool allowsFreeProbeDownload;

  /// download 被调用的次数——正文语言探测是靠 download 实现的，所以这个计数就是
  /// 「有没有为一个展示标签白烧一次配额」的直接度量。
  int downloadCalls = 0;

  @override
  final String id;
  @override
  final int priority;
  final String fileName;
  final String releaseName;
  final String language;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async =>
      ProviderBatchResult<VideoSubtitleCandidate>.success(
        <VideoSubtitleCandidate>[
          _FakeCandidate(
            providerId: id,
            remoteId: '$id:1',
            fileName: fileName,
            language: language,
            providerPriority: priority,
            releaseName: releaseName,
          ),
        ],
      );

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    downloadCalls++;
    // 一段简体中文正文，够 detectSubtitleContentLanguage 判出语言。
    // 用 join 拼行，不写转义序列（本文件经工具生成时反斜杠容易被吃掉）。
    final String srt = <String>[
      '1',
      '00:00:01,000 --> 00:00:03,000',
      '这是一句很普通的中文对白内容',
      '',
      '2',
      '00:00:04,000 --> 00:00:06,000',
      '这是另一句很普通的中文对白内容',
      '',
    ].join(String.fromCharCode(10));
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(utf8.encode(srt)),
      fileName: candidate.fileName,
      language: candidate.language,
    );
  }

  @override
  void close() {}
}

class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate({
    required super.providerId,
    required super.remoteId,
    required super.fileName,
    required super.language,
    required super.providerPriority,
    super.releaseName,
  });
}
