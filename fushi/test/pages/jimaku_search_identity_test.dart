import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';

/// 播放页「找字幕」对话框的三条用户实测缺陷（同一批反馈、同一个对话框）：
///
/// - BUG-1842 拿中文显示名去猜，刮削存下的 AniList ID 从没被用过；
/// - BUG-1843 填了集数再搜，系列列表被提前清空 → 永久失去选择面；
/// - BUG-1844 失败提示走 SnackBar，被全屏 modal 盖住，而且没有 HTTP 状态码；
/// - BUG-1847 手动检索路径不带 OSDb 文件哈希 → 精确匹配分支永远走不到。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  /// AniList 响应：`media` 为空数组；[status] 非 200 时客户端判「没问上」（degraded）。
  http_testing.MockClient anilistClient({
    int status = 200,
    List<Map<String, Object?>> media = const <Map<String, Object?>>[],
    List<String>? recordInto,
  }) =>
      http_testing.MockClient((http.Request request) async {
        recordInto?.add(request.url.toString());
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'Page': <String, Object?>{'media': media},
            },
          }),
          status,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });

  Widget host({
    required VideoSubtitleRegistry registry,
    required String saveDirectory,
    required http_testing.MockClient anilist,
    SubtitleSearchSeed seed = const SubtitleSearchSeed(),
    String initialQuery = 'Re：从零开始的异世界生活 第四季 丧失篇',
    String? videoPath,
    List<AniListMedia>? series,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: JimakuSubtitleDialog(
              initialQuery: initialQuery,
              initialApiKey: 'jimaku-key',
              onApiKeyChanged: (String _) async {},
              saveDirectory: saveDirectory,
              subtitleRegistry: () => registry,
              seed: seed,
              videoPath: videoPath,
              httpClientFactory: () async => anilist,
              debugInitialSeriesMatches: series,
            ),
          ),
        ),
      );

  Future<void> sized(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  /// 交替「假时钟 pump」与「真事件循环」推进：对话框在检索路径上会做真实文件 I/O
  /// （OSDb 指纹），而 `pumpAndSettle` 全程停在 fake-async 里，dart:io 的 future
  /// 永远不会完成——直接 pumpAndSettle 会挂到超时。
  Future<void> settleWithIo(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await tester.pump();
  }

  Future<void> search(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, t.video_jimaku_search));
    await settleWithIo(tester);
  }

  String tempDir(String prefix) =>
      Directory.systemTemp.createTempSync(prefix).path;

  group('BUG-1842 身份优先检索', () {
    testWidgets('刮削存下的 AniList id 直接用于检索，完全不碰 AniList 文本匹配', (
      WidgetTester tester,
    ) async {
      final List<String> anilistCalls = <String>[];
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_seed_id'),
          anilist: anilistClient(recordInto: anilistCalls),
          seed: const SubtitleSearchSeed(
            anilistId: 21355,
            queries: <String>[
              'Re:ゼロから始める異世界生活',
              'Re:Zero kara Hajimeru Isekai Seikatsu',
            ],
          ),
          // 播放页会用 seed.primaryQuery 预填，这里照搬那条路径。
          initialQuery: 'Re:ゼロから始める異世界生活',
        ),
      );

      await search(tester);

      expect(
        anilistCalls,
        isEmpty,
        reason: '中文译名在 AniList 上匹配不到，而刮削 id 是确定的——有 id 就别再去猜名字',
      );
      expect(provider.requests.single.media?.anilistId, 21355);
    });

    testWidgets('日文原名以外的候选词随请求下发，主词搜空后 provider 还能再试', (
      WidgetTester tester,
    ) async {
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_seed_alt'),
          anilist: anilistClient(),
          seed: const SubtitleSearchSeed(
            queries: <String>[
              'Re:ゼロから始める異世界生活',
              'Re:Zero kara Hajimeru Isekai Seikatsu',
              'Re：从零开始的异世界生活 第四季 丧失篇',
            ],
          ),
          initialQuery: 'Re:ゼロから始める異世界生活',
        ),
      );

      await search(tester);

      final VideoSubtitleSearchRequest request = provider.requests.single;
      expect(request.alternateTitles, <String>[
        'Re:Zero kara Hajimeru Isekai Seikatsu',
        'Re：从零开始的异世界生活 第四季 丧失篇',
      ]);
      expect(request.media?.originalTitle, 'Re:ゼロから始める異世界生活');
    });

    testWidgets('用户改过番名后不再套用刮削 id（按他自己的词搜）', (WidgetTester tester) async {
      final List<String> anilistCalls = <String>[];
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_seed_edit'),
          anilist: anilistClient(recordInto: anilistCalls),
          seed: const SubtitleSearchSeed(
            anilistId: 21355,
            queries: <String>['Re:ゼロから始める異世界生活'],
          ),
          initialQuery: 'Re:ゼロから始める異世界生活',
        ),
      );

      await tester.enterText(
        find.widgetWithText(TextField, t.video_jimaku_query),
        '別のアニメ',
      );
      await search(tester);

      expect(anilistCalls, isNotEmpty, reason: '用户自己改了番名，应按他的词重新解析系列');
      expect(provider.requests.single.media?.anilistId, isNull);
      expect(provider.requests.single.alternateTitles, isEmpty);
    });
  });

  group('BUG-1843 系列列表不被提前清空', () {
    testWidgets('填了集数再搜（番名没变）+ AniList 没问上（429）：已有的系列列表不被清空', (
      WidgetTester tester,
    ) async {
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
            _RecordingSubtitleProvider(),
          ]),
          saveDirectory: tempDir('fushi_series_keep'),
          // 429 = 限流：客户端判 degraded，media 恒空。
          anilist: anilistClient(status: 429),
          initialQuery: 'Re:Zero',
          series: const <AniListMedia>[
            AniListMedia(
              id: 21355,
              romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu',
            ),
            AniListMedia(id: 119661, romaji: 'Re:Zero 2nd Season Part 2'),
          ],
        ),
      );
      expect(find.text('Re:Zero 2nd Season Part 2'), findsOneWidget);

      // 只在集数框填个数字再搜（用户报的正是这一步之后系列没了）。
      await tester.enterText(
        find.widgetWithText(TextField, t.video_jimaku_episode),
        '4',
      );
      await search(tester);

      expect(
        find.text('Re:Zero 2nd Season Part 2'),
        findsOneWidget,
        reason: '系列列表要等一次网络往返才回填，提前清空会让用户在失败时永久失去选择面',
      );
    });

    testWidgets('AniList 明确答「查无此番」（200 + 空）时列表照常替换，不留旧结果赖着', (
      WidgetTester tester,
    ) async {
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
            _RecordingSubtitleProvider(),
          ]),
          saveDirectory: tempDir('fushi_series_replace'),
          // 200 + 空 media = AniList 明确答「没有这部番」，不是「没问上」。
          anilist: anilistClient(),
          initialQuery: 'Re:Zero',
          series: const <AniListMedia>[
            AniListMedia(
              id: 21355,
              romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu',
            ),
            AniListMedia(id: 119661, romaji: 'Re:Zero 2nd Season Part 2'),
          ],
        ),
      );
      // 番名不变（预置列表是「自动选中首条」，不是用户手点，所以不会走系列捷径，
      // 这一搜会真的去问 AniList）。
      await search(tester);

      expect(
        find.text('Re:Zero 2nd Season Part 2'),
        findsNothing,
        reason: '「没问上」才保留旧列表；「问了、真没有」必须如实替换，否则用户对着一批'
            '与当前搜索词无关的系列以为还能选',
      );
    });

    testWidgets('用户手点过的系列在同番名重搜时仍然生效（零结果也不偷偷换回文本搜）', (
      WidgetTester tester,
    ) async {
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
      final List<String> anilistCalls = <String>[];
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_series_pick'),
          anilist: anilistClient(recordInto: anilistCalls),
          initialQuery: 'Re:Zero',
          series: const <AniListMedia>[
            AniListMedia(
              id: 21355,
              romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu',
            ),
            AniListMedia(id: 119661, romaji: 'Re:Zero 2nd Season Part 2'),
          ],
        ),
      );

      await tester.tap(find.text('Re:Zero 2nd Season Part 2'));
      await settleWithIo(tester);
      anilistCalls.clear();

      // 只改集数再搜：应直接在用户选定的系列里重列，不再问一次 AniList。
      await tester.enterText(
        find.widgetWithText(TextField, t.video_jimaku_episode),
        '4',
      );
      await search(tester);

      expect(
        anilistCalls,
        isEmpty,
        reason: '用户已经指定了系列，重跑 AniList 只是白等 + 多一次限流机会',
      );
      expect(provider.requests.last.media?.anilistId, 119661);
      expect(find.text('Re:Zero 2nd Season Part 2'), findsOneWidget);
    });
  });

  group('BUG-1844 失败原因可见', () {
    testWidgets('下载失败的原因显示在对话框内部，并带上 HTTP 状态码', (WidgetTester tester) async {
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider(
        downloadFailure: const ExternalProviderFailure(
          providerId: 'jimaku',
          operation: 'download',
          kind: ExternalProviderFailureKind.forbidden,
          message: 'Jimaku returned HTTP 403',
          statusCode: 403,
        ),
      );
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_dl_fail'),
          anilist: anilistClient(),
        ),
      );
      await search(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('jimaku-file-view-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('recorded.ep01.ja.srt'));
      await settleWithIo(tester);

      // 对话框是全屏 modal，SnackBar 会被它整个盖住——错误必须画在对话框内部。
      expect(find.byKey(kSubtitleNoticeBannerKey), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(
        find.textContaining('403'),
        findsOneWidget,
        reason: '401/429/404 是完全不同的三件事，只说「下载失败」等于什么都没说',
      );
    });

    testWidgets('搜索时所有来源都挂了 → 说「搜索失败」而不是「没有找到字幕」', (WidgetTester tester) async {
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider(
        searchFailure: const ExternalProviderFailure(
          providerId: 'jimaku',
          operation: 'search',
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'Jimaku returned HTTP 401',
          statusCode: 401,
        ),
      );
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_search_fail'),
          anilist: anilistClient(),
        ),
      );
      await search(tester);

      expect(find.byKey(kSubtitleNoticeBannerKey), findsOneWidget);
      expect(
        find.textContaining('401'),
        findsOneWidget,
        reason: 'key 过期时用户换多少次关键词都不会好，必须把真实原因说出来',
      );
    });

    testWidgets('搜到结果时不显示任何提示条（不吓唬用户）', (WidgetTester tester) async {
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
            _RecordingSubtitleProvider(),
          ]),
          saveDirectory: tempDir('fushi_ok'),
          anilist: anilistClient(),
        ),
      );
      await search(tester);
      expect(find.byKey(kSubtitleNoticeBannerKey), findsNothing);
    });
  });

  group('BUG-1847 手动检索带 OSDb 文件哈希', () {
    testWidgets('本地视频：请求带上文件指纹（体积 + movie hash）', (WidgetTester tester) async {
      // OSDb movie hash 读首尾各 64KiB，文件必须够大才算得出来。
      final Directory dir = Directory.systemTemp.createTempSync(
        'fushi_fingerprint',
      );
      final File video = File('${dir.path}${Platform.pathSeparator}ep01.mkv');
      video.writeAsBytesSync(Uint8List(256 * 1024));

      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_fp_save'),
          anilist: anilistClient(),
          videoPath: video.path,
        ),
      );
      await search(tester);

      final LocalVideoFingerprint? fingerprint =
          provider.requests.single.fingerprint;
      expect(
        fingerprint,
        isNotNull,
        reason: 'OpenSubtitles 的 moviehash 精确匹配分支在手动路径上此前永远走不到',
      );
      expect(fingerprint!.fileSize, 256 * 1024);
      expect(fingerprint.openSubtitlesMovieHash, isNotNull);
      expect(fingerprint.fileName, 'ep01.mkv');
    });

    testWidgets('远端流（无本地文件）：不带指纹，也不因此报错', (WidgetTester tester) async {
      final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
      await sized(
        tester,
        host(
          registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
          saveDirectory: tempDir('fushi_fp_remote'),
          anilist: anilistClient(),
        ),
      );
      await search(tester);

      expect(provider.requests.single.fingerprint, isNull);
      expect(find.byKey(kSubtitleNoticeBannerKey), findsNothing);
    });
  });
}

/// 记录收到的搜索请求的假 provider；可注入搜索 / 下载失败。
class _RecordingSubtitleProvider implements VideoSubtitleProvider {
  _RecordingSubtitleProvider({this.searchFailure, this.downloadFailure});

  final ExternalProviderFailure? searchFailure;
  final ExternalProviderFailure? downloadFailure;

  final List<VideoSubtitleSearchRequest> requests =
      <VideoSubtitleSearchRequest>[];

  @override
  String get id => 'jimaku';

  @override
  int get priority => 100;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    requests.add(request);
    final ExternalProviderFailure? failure = searchFailure;
    if (failure != null) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(failure);
    }
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[
        _FakeCandidate(
          providerId: id,
          remoteId: '$id:1',
          fileName: 'recorded.ep01.ja.srt',
          language: 'ja',
          providerPriority: priority,
          releaseName: 'Recorded Entry',
        ),
      ],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    final ExternalProviderFailure? failure = downloadFailure;
    if (failure != null) throw failure;
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(utf8.encode('1')),
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
