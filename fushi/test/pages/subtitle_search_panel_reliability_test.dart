import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart'
    show JimakuSubtitleDialog;
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, MediaCollectionRow, VideoBookRow;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart'
    show AutomaticSubtitleAligner;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:material_ui/material_ui.dart';

/// 本集字幕面板的两组可靠性契约：
/// - BUG-4799：搜索有代次——后提交的一轮赢，迟到的旧一轮不覆盖结果、不提前收转圈；
///   保存 key 抛错不会让搜索钮永久禁用。
/// - BUG-4802：多选——全选 / 反选只作用于筛选后看得见的；重搜清勾选；部分失败不
///   自动关页，已落盘的逐条交给宿主、关页时带回；页面一关（路由被 pop）就不再落盘。
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

/// 只开「本集」作用域的工作台宿主：一个假来源、AniList 查无此番。
class _WorkbenchHost implements SubtitleWorkbenchHost {
  _WorkbenchHost(VideoSubtitleProvider provider)
    : _registry = VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]);

  final VideoSubtitleRegistry _registry;

  /// 只有「整个合集」作用域读数据库，这里的用例不开它。
  @override
  FushiDatabase get database => throw UnimplementedError();
  @override
  Future<VideoSubtitleRegistry?> subtitleRegistry() async => _registry;
  @override
  String get jimakuApiKey => 'key';
  @override
  Future<void> setJimakuApiKey(String key) async {}
  @override
  Future<http.Client> createHttpClient() => _noAniListHits();
  @override
  String? preferredLanguageFor(String seriesKey) => null;
  @override
  Future<void> setPreferredLanguage(String seriesKey, String langCode) async {}
  @override
  String? get defaultContentLanguage => null;
  @override
  Future<void> persistRemoteSubtitle(String bookUid, String path) async {}
  @override
  AutomaticSubtitleAligner? get subtitleAligner => null;
}

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
    Future<VideoSubtitleRegistry?> Function()? subtitleRegistry,
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
              subtitleRegistry: subtitleRegistry ?? () async => registry,
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

  group('BUG-4799 搜索代次', () {
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

    testWidgets('代次在提交时刻分配：两次来源探测乱序返回，仍是后提交的词赢', (WidgetTester tester) async {
      // Jimaku key 框为空时，检索先问一次「有没有配置的来源」再往下走。头两次探测
      // 挂起、由测试决定谁先回；之后的取 registry 一律立即返回。
      final VideoSubtitleRegistry registry =
          VideoSubtitleRegistry(<VideoSubtitleProvider>[
            _FakeProvider(
              onSearch: (VideoSubtitleSearchRequest request) async =>
                  _hits('${request.query} - 01.ja.srt'),
            ),
          ]);
      final List<Completer<VideoSubtitleRegistry?>> probes =
          <Completer<VideoSubtitleRegistry?>>[];
      bool gated = false;
      await pumpPanel(
        tester,
        provider: _FakeProvider(),
        initialApiKey: '',
        subtitleRegistry: () {
          if (!gated || probes.length >= 2) {
            return Future<VideoSubtitleRegistry?>.value(registry);
          }
          final Completer<VideoSubtitleRegistry?> probe =
              Completer<VideoSubtitleRegistry?>();
          probes.add(probe);
          return probe.future;
        },
      );
      gated = true;
      await tester.enterText(fieldWithText('Alpha'), 'Alpha');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(probes, hasLength(1));
      await tester.enterText(fieldWithText('Alpha'), 'Beta');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(probes, hasLength(2));

      // 后提交的 Beta 先探完、先出结果。
      probes[1].complete(registry);
      await settleSearch(tester);
      expect(find.textContaining('Beta - 01'), findsWidgets);

      // 先提交的 Alpha 这时才探完：它在提交时就已经被顶掉，不得再发起检索。
      probes[0].complete(registry);
      await settleSearch(tester);
      expect(
        find.textContaining('Alpha - 01'),
        findsNothing,
        reason: '代次若在探测返回后才分配，先提交的旧词会拿到更大的代次、反过来赢',
      );
      expect(find.textContaining('Beta - 01'), findsWidgets);
      expect(searchEnabled(tester), isTrue);
    });
  });

  group('BUG-4802 多选', () {
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

      VideoSubtitleDownload body(VideoSubtitleCandidate c) =>
          VideoSubtitleDownload(
            bytes: Uint8List.fromList(utf8.encode('1')),
            fileName: c.fileName,
            language: c.language,
          );

      /// 在一张「播放页」上经 [SubtitleWorkbenchPage.open] 推工作台并搜出 [sources]。
      /// 返回 open() 的 future——播放页拿到的就是它。
      Future<Future<List<String>?>> openWorkbench(
        WidgetTester tester,
        _Download onDownload, {
        SubtitleCollectionSpec? collection,
      }) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          TranslationProvider(
            child: const MaterialApp(
              home: Scaffold(body: Center(child: Text('player-page'))),
            ),
          ),
        );
        final Future<List<String>?> result = SubtitleWorkbenchPage.open(
          tester.element(find.text('player-page')),
          host: _WorkbenchHost(
            _FakeProvider(
              onSearch: (_) async =>
                  ProviderBatchResult<VideoSubtitleCandidate>.success(
                    sources(),
                  ),
              onDownload: onDownload,
            ),
          ),
          saveDirectory: saveDir.path,
          episode: const SubtitleEpisodeSearchSpec(
            initialQuery: 'Show',
            seriesKey: 'show',
          ),
          collection: collection,
        );
        await tester.pumpAndSettle();
        await tester.tap(searchButton());
        await settleSearch(tester);
        await tester.pumpAndSettle();
        return result;
      }

      /// 关页之后再推进一小段：比退场转场（约 300 ms）短，面板此时仍 mounted。
      Future<void> driveInsideExitTransition(WidgetTester tester) async {
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
      }

      testWidgets('工作台：部分失败后用户自己返回，open() 的返回值里有已落盘的那条', (
        WidgetTester tester,
      ) async {
        final SubtitleVersionGroup group = jaGroup(sources());
        final Future<List<String>?> result = await openWorkbench(
          tester,
          download,
        );
        bool closed = false;
        List<String>? returned;
        unawaited(
          result.then((List<String>? paths) {
            closed = true;
            returned = paths;
          }),
        );
        await expandAndTick(tester, group, <VideoSubtitleCandidate>[
          for (final VideoSubtitleCandidate c in group.members)
            if (c.episode != 3) c,
        ]);
        await tester.tap(
          find.byKey(const ValueKey<String>('subtitle-batch-download')),
        );
        await driveIo(
          tester,
          () => find.byKey(kSubtitleNoticeBannerKey).evaluate().isNotEmpty,
        );
        expect(closed, isFalse, reason: '部分失败不自动关页');
        expect(find.textContaining('404'), findsOneWidget);

        // 系统返回：面板没有主动带回任何路径，全靠 open() 在路由外收下的那份。
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(closed, isTrue);
        expect(returned, hasLength(1), reason: '接线断了的话，部分失败后已下好的字幕一条都回不到播放页');
        expect(File(returned!.single).existsSync(), isTrue);
        expect(saveDir.listSync(), hasLength(1));
      });

      testWidgets('工作台：批量途中返回，退场转场里才回来的那条不落盘、不成孤儿', (
        WidgetTester tester,
      ) async {
        final SubtitleVersionGroup group = jaGroup(sources());
        final Completer<VideoSubtitleDownload> late =
            Completer<VideoSubtitleDownload>();
        bool lateRequested = false;
        final Future<List<String>?> result = await openWorkbench(tester, (
          VideoSubtitleCandidate c,
        ) {
          if (c.episode != 3) {
            return Future<VideoSubtitleDownload>.value(body(c));
          }
          lateRequested = true;
          return late.future;
        });
        bool closed = false;
        List<String>? returned;
        unawaited(
          result.then((List<String>? paths) {
            closed = true;
            returned = paths;
          }),
        );
        final VideoSubtitleCandidate slow = group.members.firstWhere(
          (VideoSubtitleCandidate c) => c.episode == 3,
        );
        await expandAndTick(tester, group, <VideoSubtitleCandidate>[
          group.members.firstWhere(
            (VideoSubtitleCandidate c) => c.episode == 1,
          ),
          slow,
        ]);
        await tester.tap(
          find.byKey(const ValueKey<String>('subtitle-batch-download')),
        );
        await driveIo(
          tester,
          () => lateRequested && saveDir.listSync().length == 1,
        );
        expect(lateRequested, isTrue);
        expect(saveDir.listSync(), hasLength(1));

        // 第 3 集还在下载时返回：open() 当下就把结果交给播放页，而面板要等转场
        // 跑完才 dispose。第 3 集就在这段时间里回来。
        await tester.binding.handlePopRoute();
        late.complete(body(slow));
        await driveInsideExitTransition(tester);
        expect(closed, isTrue);
        expect(returned, hasLength(1));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        expect(
          saveDir.listSync(),
          hasLength(1),
          reason: '返回值已经交出去了，之后落盘的文件没有人登记',
        );
        expect(find.text('player-page'), findsOneWidget);
      });

      testWidgets('工作台：本集下载途中锁住作用域开关与重搜，下完解锁', (WidgetTester tester) async {
        final SubtitleVersionGroup group = jaGroup(sources());
        final Completer<VideoSubtitleDownload> late =
            Completer<VideoSubtitleDownload>();
        bool lateRequested = false;
        // 合集作用域只是为了让开关出现；锁住时不会切过去，数据库不会被读。
        final SubtitleCollectionSpec collection = SubtitleCollectionSpec(
          collection: MediaCollectionRow(
            origin: 'user',
            organizeAliases: '',
            id: 1,
            name: 'Show',
            collectionType: 'collection',
            coverSource: null,
            sortOrder: 0,
            createdAt: 0,
            orderUpdatedAt: 0,
          ),
          members: const <VideoBookRow>[],
        );
        await openWorkbench(tester, (VideoSubtitleCandidate c) {
          if (c.episode != 3) {
            return Future<VideoSubtitleDownload>.value(body(c));
          }
          lateRequested = true;
          return late.future;
        }, collection: collection);
        final Finder toCollection = find.byKey(
          const ValueKey<String>('subtitle-workbench-scope-collection'),
        );
        expect(tester.widget<FushiIconButton>(toCollection).enabled, isTrue);

        await expandAndTick(tester, group, <VideoSubtitleCandidate>[
          group.members.firstWhere(
            (VideoSubtitleCandidate c) => c.episode == 1,
          ),
          group.members.firstWhere(
            (VideoSubtitleCandidate c) => c.episode == 3,
          ),
        ]);
        await tester.tap(
          find.byKey(const ValueKey<String>('subtitle-batch-download')),
        );
        await driveIo(
          tester,
          () => lateRequested && saveDir.listSync().length == 1,
        );
        expect(lateRequested, isTrue);

        // 修复前：开关可点，一切到「整个合集」本集面板就 dispose，第 3 集回来时按
        // 「页面已关」静默不落盘，用户什么提示也看不到。
        final FushiIconButton locked = tester.widget<FushiIconButton>(
          toCollection,
        );
        expect(locked.enabled, isFalse);
        expect(locked.tooltip, t.video_subtitle_scope_locked_downloading);
        // 修复前：搜索钮可点、输入框回车照样重搜，清掉候选与勾选，批量的进度落在
        // 看不见的行上。
        expect(searchEnabled(tester), isFalse);
        await tester.showKeyboard(fieldWithText('Show'));
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(
          find.byType(BatchActionBar),
          findsOneWidget,
          reason: '回车没有重搜：勾选（批量栏）还在',
        );

        // 第 3 集失败收尾（部分失败不关页）：开关与搜索恢复可用。
        late.completeError(
          const ExternalProviderFailure(
            providerId: 'fake',
            operation: 'download',
            kind: ExternalProviderFailureKind.notFound,
            message: 'gone',
            statusCode: 404,
          ),
        );
        await driveIo(
          tester,
          () => find.byKey(kSubtitleNoticeBannerKey).evaluate().isNotEmpty,
        );
        expect(tester.widget<FushiIconButton>(toCollection).enabled, isTrue);
        expect(searchEnabled(tester), isTrue);
      });

      testWidgets('工作台：单条下载途中返回，迟到的那条不落盘，也不 pop 掉底下的播放页', (
        WidgetTester tester,
      ) async {
        final SubtitleVersionGroup group = jaGroup(sources());
        final Completer<VideoSubtitleDownload> late =
            Completer<VideoSubtitleDownload>();
        bool lateRequested = false;
        final Future<List<String>?> result = await openWorkbench(tester, (
          VideoSubtitleCandidate c,
        ) {
          lateRequested = true;
          return late.future;
        });
        bool closed = false;
        List<String>? returned;
        unawaited(
          result.then((List<String>? paths) {
            closed = true;
            returned = paths;
          }),
        );
        final VideoSubtitleCandidate slow = group.members.first;
        await tester.tap(
          find.byKey(ValueKey<String>('subtitle-version-${group.key}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey<String>('subtitle-file-${slow.identityKey}')),
        );
        await driveIo(tester, () => lateRequested);
        expect(lateRequested, isTrue);

        await tester.binding.handlePopRoute();
        late.complete(body(slow));
        await driveInsideExitTransition(tester);
        expect(closed, isTrue);
        expect(returned, isNull);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        expect(saveDir.listSync(), isEmpty);
        expect(
          find.text('player-page'),
          findsOneWidget,
          reason: '面板的下载完成回调是 pop：页面已关时再调，弹掉的是底下那一页',
        );
      });

      testWidgets('对话框壳：部分失败后点「取消」带回已落盘的第一条', (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final List<VideoSubtitleCandidate> all = sources();
        final SubtitleVersionGroup group = jaGroup(all);
        final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
          <VideoSubtitleProvider>[_FakeProvider(onDownload: download)],
        );
        await tester.pumpWidget(
          TranslationProvider(
            child: const MaterialApp(
              home: Scaffold(body: Center(child: Text('player-page'))),
            ),
          ),
        );
        bool closed = false;
        String? returned;
        unawaited(
          showDialog<String>(
            context: tester.element(find.text('player-page')),
            builder: (_) => JimakuSubtitleDialog(
              initialQuery: 'Show',
              initialApiKey: 'key',
              onApiKeyChanged: (_) async {},
              saveDirectory: saveDir.path,
              subtitleRegistry: () async => registry,
              httpClientFactory: _noAniListHits,
              debugInitialCandidates: _seeded(all),
            ),
          ).then((String? path) {
            closed = true;
            returned = path;
          }),
        );
        await tester.pumpAndSettle();
        await expandAndTick(tester, group, <VideoSubtitleCandidate>[
          for (final VideoSubtitleCandidate c in group.members)
            if (c.episode != 3) c,
        ]);
        await tester.tap(
          find.byKey(const ValueKey<String>('subtitle-batch-download')),
        );
        await driveIo(
          tester,
          () => find.byKey(kSubtitleNoticeBannerKey).evaluate().isNotEmpty,
        );
        expect(closed, isFalse);

        await tester.tap(find.text(t.dialog_cancel));
        await tester.pumpAndSettle();
        expect(closed, isTrue);
        expect(returned, isNotNull, reason: '取消曾一律带回 null，已下好的那条没人登记');
        expect(File(returned!).existsSync(), isTrue);
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
