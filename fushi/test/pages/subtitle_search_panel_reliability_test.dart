import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart'
    show workbenchEpisodePaths;
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:material_ui/material_ui.dart';

/// 本集字幕面板的两组可靠性契约：
/// - BUG-4795：搜索有代次——后提交的一轮赢，迟到的旧一轮不覆盖结果、不提前收转圈；
///   保存 key 抛错不会让搜索钮永久禁用。
/// - BUG-4794：多选——全选 / 反选只作用于筛选后看得见的；重搜清勾选；部分失败不
///   自动关页，已落盘的逐条交给宿主。
class _Cand extends VideoSubtitleCandidate {
  _Cand(String name, {int? episode, String language = 'ja'})
    : super(
        providerId: 'fake',
        remoteId: name,
        fileName: name,
        language: language,
        providerPriority: 1,
        episode: episode,
        collectionId: 'c1',
        collectionLabel: 'Show (2026)',
      );
}

typedef _Search =
    Future<ProviderBatchResult<VideoSubtitleCandidate>> Function(
      VideoSubtitleSearchRequest request,
    );
typedef _Download =
    Future<VideoSubtitleDownload> Function(VideoSubtitleCandidate candidate);

class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider({this.onSearch, this.onDownload});

  final _Search? onSearch;
  final _Download? onDownload;

  @override
  String get id => 'fake';
  @override
  int get priority => 1;
  @override
  bool get allowsFreeProbeDownload => false;
  @override
  void close() {}

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) =>
      onSearch?.call(request) ??
      Future<ProviderBatchResult<VideoSubtitleCandidate>>.value(
        ProviderBatchResult<VideoSubtitleCandidate>.success(
          const <VideoSubtitleCandidate>[],
        ),
      );

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      onDownload?.call(candidate) ?? (throw UnimplementedError());
}

ProviderBatchResult<VideoSubtitleCandidate> _hits(String name) =>
    ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[_Cand(name, episode: 1)],
    );

/// AniList 一律回「查无此番」：面板退回按输入框里的词做文本搜。
Future<http.Client> _noAniListHits() async => http_testing.MockClient(
  (http.Request _) async => http.Response(
    '{"data":{"Page":{"media":[]}}}',
    200,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  ),
);

List<JimakuCandidate> _seeded(List<VideoSubtitleCandidate> sources) =>
    <JimakuCandidate>[
      for (final VideoSubtitleCandidate source in sources)
        JimakuCandidate.fromProvider(source),
    ];

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<void> pumpPanel(
    WidgetTester tester, {
    required VideoSubtitleProvider provider,
    String initialQuery = 'Alpha',
    String initialApiKey = 'key',
    Future<void> Function(String key)? onApiKeyChanged,
    void Function(List<String> paths)? onDownloaded,
    void Function(String path)? onSubtitleSaved,
    String saveDirectory = '/tmp/fushi-sub',
    List<JimakuCandidate>? seeded,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
      <VideoSubtitleProvider>[provider],
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SubtitleSearchPanel(
              onDownloaded: onDownloaded ?? (_) {},
              onSubtitleSaved: onSubtitleSaved,
              initialQuery: initialQuery,
              initialApiKey: initialApiKey,
              onApiKeyChanged: onApiKeyChanged ?? (_) async {},
              saveDirectory: saveDirectory,
              subtitleRegistry: () async => registry,
              httpClientFactory: _noAniListHits,
              debugInitialCandidates: seeded,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder searchButton() =>
      find.widgetWithText(FilledButton, t.video_jimaku_search);

  bool searchEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(searchButton()).onPressed != null;

  Finder fieldWithText(String text) => find.byWidgetPredicate(
    (Widget w) => w is TextField && w.controller?.text == text,
  );

  /// 推进一轮检索里的若干 await（首帧、AniList、registry、provider）。
  Future<void> settleSearch(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('BUG-4795 搜索代次', () {
    /// 提交 Alpha（挂起）→ 改词回车提交 Beta（挂起）。返回两轮各自的 completer。
    Future<Map<String, Completer<ProviderBatchResult<VideoSubtitleCandidate>>>>
    submitTwoRounds(WidgetTester tester) async {
      final Map<String, Completer<ProviderBatchResult<VideoSubtitleCandidate>>>
      pending =
          <String, Completer<ProviderBatchResult<VideoSubtitleCandidate>>>{};
      await pumpPanel(
        tester,
        provider: _FakeProvider(
          onSearch: (VideoSubtitleSearchRequest request) =>
              (pending[request.query ?? ''] ??=
                      Completer<ProviderBatchResult<VideoSubtitleCandidate>>())
                  .future,
        ),
      );
      await tester.tap(searchButton());
      await settleSearch(tester);
      expect(pending.keys, <String>['Alpha'], reason: '第一轮已发到 provider');
      expect(searchEnabled(tester), isFalse);

      // 搜索中在输入框里改词回车：onSubmitted 不看 _searching，第二轮照发。
      await tester.enterText(fieldWithText('Alpha'), 'Beta');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleSearch(tester);
      expect(pending.keys, <String>['Alpha', 'Beta']);
      return pending;
    }

    testWidgets('旧一轮先返回：不落结果、不提前收转圈；新一轮返回后显示新结果', (WidgetTester tester) async {
      final Map<String, Completer<ProviderBatchResult<VideoSubtitleCandidate>>>
      pending = await submitTwoRounds(tester);

      pending['Alpha']!.complete(_hits('Alpha - 01.ja.srt'));
      await settleSearch(tester);
      expect(find.textContaining('Alpha - 01'), findsNothing);
      expect(
        searchEnabled(tester),
        isFalse,
        reason: '被顶掉的旧一轮返回时，新一轮还在路上，转圈不能收',
      );

      pending['Beta']!.complete(_hits('Beta - 01.ja.srt'));
      await settleSearch(tester);
      expect(find.textContaining('Beta - 01'), findsWidgets);
      expect(searchEnabled(tester), isTrue);
    });

    testWidgets('旧一轮后返回：不覆盖后提交那一轮的结果', (WidgetTester tester) async {
      final Map<String, Completer<ProviderBatchResult<VideoSubtitleCandidate>>>
      pending = await submitTwoRounds(tester);

      pending['Beta']!.complete(_hits('Beta - 01.ja.srt'));
      await settleSearch(tester);
      expect(find.textContaining('Beta - 01'), findsWidgets);
      expect(searchEnabled(tester), isTrue);

      pending['Alpha']!.complete(_hits('Alpha - 01.ja.srt'));
      await settleSearch(tester);
      expect(
        find.textContaining('Alpha - 01'),
        findsNothing,
        reason: '显示的必须是最后提交的那一轮，不是最后返回的',
      );
      expect(find.textContaining('Beta - 01'), findsWidgets);
      expect(searchEnabled(tester), isTrue);
    });

    testWidgets('保存 key 抛错：搜索钮恢复可用，面板内给出失败提示', (WidgetTester tester) async {
      int searches = 0;
      await pumpPanel(
        tester,
        initialApiKey: 'old-key',
        onApiKeyChanged: (_) async => throw StateError('prefs write failed'),
        provider: _FakeProvider(
          onSearch: (_) async {
            searches++;
            return _hits('Alpha - 01.ja.srt');
          },
        ),
      );
      await tester.enterText(fieldWithText('old-key'), 'new-key');
      await tester.tap(searchButton());
      await settleSearch(tester);

      expect(
        searchEnabled(tester),
        isTrue,
        reason: 'onApiKeyChanged 抛错后 _searching 必须复位，否则搜索钮灰到关页',
      );
      expect(find.byKey(kSubtitleNoticeBannerKey), findsOneWidget);
      expect(find.textContaining(t.video_jimaku_search_failed), findsOneWidget);
      expect(searches, 0, reason: 'key 没存上，这一轮不该继续发检索');
    });
  });

  group('BUG-4794 多选', () {
    List<VideoSubtitleCandidate> sources() => <VideoSubtitleCandidate>[
      for (int ep = 1; ep <= 3; ep++)
        _Cand('[SubsPlease] Show - 0$ep.ass', episode: ep),
      _Cand('[MoeSubs] Show - 01.srt', episode: 1, language: 'zh'),
    ];

    SubtitleVersionGroup jaGroup(List<VideoSubtitleCandidate> all) =>
        buildSubtitleVersionGroups(
          all,
        ).firstWhere((SubtitleVersionGroup g) => g.members.length > 1);

    Finder checkboxOf(VideoSubtitleCandidate candidate) => find.descendant(
      of: find.byKey(
        ValueKey<String>('subtitle-file-${candidate.identityKey}'),
      ),
      matching: find.byType(Checkbox),
    );

    Future<void> expandAndTick(
      WidgetTester tester,
      SubtitleVersionGroup group,
      List<VideoSubtitleCandidate> ticks,
    ) async {
      await tester.tap(
        find.byKey(ValueKey<String>('subtitle-version-${group.key}')),
      );
      await tester.pumpAndSettle();
      for (final VideoSubtitleCandidate candidate in ticks) {
        await tester.tap(checkboxOf(candidate));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('全选 / 反选只作用于筛选后看得见的；重搜清掉勾选', (WidgetTester tester) async {
      final List<VideoSubtitleCandidate> all = sources();
      final SubtitleVersionGroup group = jaGroup(all);
      await pumpPanel(
        tester,
        initialQuery: 'Show',
        provider: _FakeProvider(),
        seeded: _seeded(all),
      );
      await expandAndTick(tester, group, <VideoSubtitleCandidate>[
        group.members.first,
      ]);
      expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);

      // 筛到日语后全选：只勾看得见的 3 条，中文那条不被带上。
      await tester.tap(find.text(jimakuLanguageLabel('ja')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.batch_select_all));
      await tester.pumpAndSettle();
      expect(
        find.text(t.batch_selected_count(n: 3)),
        findsOneWidget,
        reason: '全选曾取全量候选（4 条），把筛掉的语言也一起勾上',
      );

      // 筛到中文后反选：只翻转看得见的那 1 条，日语的 3 条勾选原样保留。
      await tester.tap(find.text(jimakuLanguageLabel('zh')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.batch_invert_selection));
      await tester.pumpAndSettle();
      expect(find.text(t.batch_selected_count(n: 4)), findsOneWidget);

      // 重搜：新结果里没有这些文件，批量栏必须消失。
      await tester.tap(searchButton());
      await settleSearch(tester);
      expect(
        find.byType(BatchActionBar),
        findsNothing,
        reason: '重搜后还显示「已选 N」，点下载下的是已经不在列表里的文件',
      );
    });

    group('部分失败', () {
      late Directory saveDir;
      setUp(() {
        saveDir = Directory.systemTemp.createTempSync('fushi_sub_partial');
      });
      tearDown(() {
        if (saveDir.existsSync()) saveDir.deleteSync(recursive: true);
      });

      Future<VideoSubtitleDownload> download(VideoSubtitleCandidate c) async {
        if (c.episode == 2) {
          throw const ExternalProviderFailure(
            providerId: 'fake',
            operation: 'download',
            kind: ExternalProviderFailureKind.notFound,
            message: 'gone',
            statusCode: 404,
          );
        }
        return VideoSubtitleDownload(
          bytes: Uint8List.fromList(utf8.encode('1')),
          fileName: c.fileName,
          language: c.language,
        );
      }

      /// 落盘是真实文件 I/O：交替「假时钟 pump」与「真事件循环」推进到 [done]。
      Future<void> driveIo(WidgetTester tester, bool Function() done) async {
        for (int i = 0; i < 400 && !done(); i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        await tester.pump();
      }

      testWidgets('宿主接了 onSubtitleSaved：不自动关页，原因留在面板里，失败的仍勾着', (
        WidgetTester tester,
      ) async {
        final List<VideoSubtitleCandidate> all = sources();
        final SubtitleVersionGroup group = jaGroup(all);
        final VideoSubtitleCandidate ok = group.members.firstWhere(
          (VideoSubtitleCandidate c) => c.episode == 1,
        );
        final VideoSubtitleCandidate bad = group.members.firstWhere(
          (VideoSubtitleCandidate c) => c.episode == 2,
        );
        final List<String> savedPaths = <String>[];
        List<String>? closedWith;
        await pumpPanel(
          tester,
          initialQuery: 'Show',
          provider: _FakeProvider(onDownload: download),
          seeded: _seeded(all),
          saveDirectory: saveDir.path,
          onSubtitleSaved: savedPaths.add,
          onDownloaded: (List<String> paths) => closedWith = paths,
        );
        await expandAndTick(tester, group, <VideoSubtitleCandidate>[ok, bad]);
        await tester.tap(
          find.byKey(const ValueKey<String>('subtitle-batch-download')),
        );
        await driveIo(
          tester,
          () =>
              savedPaths.isNotEmpty &&
              find.byKey(kSubtitleNoticeBannerKey).evaluate().isNotEmpty,
        );

        expect(savedPaths, hasLength(1));
        expect(File(savedPaths.single).existsSync(), isTrue);
        expect(closedWith, isNull, reason: '部分失败时自动关页会把刚画出来的失败提示一起带走');
        expect(
          find.textContaining(t.download_batch_failed(n: 1)),
          findsOneWidget,
        );
        expect(
          find.textContaining('404'),
          findsOneWidget,
          reason: '失败原因要带状态码，不是只说「失败 1 条」',
        );
        // 成功的一条取消勾选，剩下勾着的就是要重试的那条。
        expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);
        // 提示条出现时结果区多包了一层，版本卡的展开态随之重置：重新展开再看勾选。
        await tester.tap(
          find.byKey(ValueKey<String>('subtitle-version-${group.key}')),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(checkboxOf(bad)).value, isTrue);
        expect(tester.widget<Checkbox>(checkboxOf(ok)).value, isFalse);
      });

      testWidgets('宿主没接 onSubtitleSaved：已落盘的仍随 onDownloaded 带回（旧出口）', (
        WidgetTester tester,
      ) async {
        final List<VideoSubtitleCandidate> all = sources();
        final SubtitleVersionGroup group = jaGroup(all);
        List<String>? closedWith;
        await pumpPanel(
          tester,
          initialQuery: 'Show',
          provider: _FakeProvider(onDownload: download),
          seeded: _seeded(all),
          saveDirectory: saveDir.path,
          onDownloaded: (List<String> paths) => closedWith = paths,
        );
        await expandAndTick(tester, group, <VideoSubtitleCandidate>[
          for (final VideoSubtitleCandidate c in group.members)
            if (c.episode != 3) c,
        ]);
        await tester.tap(
          find.byKey(const ValueKey<String>('subtitle-batch-download')),
        );
        await driveIo(tester, () => closedWith != null);
        expect(closedWith, hasLength(1));
        expect(File(closedWith!.single).existsSync(), isTrue);
      });
    });

    test('workbenchEpisodePaths：显式带回的排前面，逐条落盘的补在后面且不重复', () {
      expect(
        workbenchEpisodePaths(explicit: null, savedWhileOpen: <String>[]),
        isNull,
        reason: '用户直接返回、什么也没下',
      );
      expect(
        workbenchEpisodePaths(explicit: null, savedWhileOpen: <String>['a']),
        <String>['a'],
        reason: '部分失败后用户自己点返回：已落盘的仍要带回播放页',
      );
      expect(
        workbenchEpisodePaths(
          explicit: <String>['b', 'c'],
          savedWhileOpen: <String>['a', 'b', 'c'],
        ),
        <String>['b', 'c', 'a'],
      );
    });
  });
}
