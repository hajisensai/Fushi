import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';
import 'package:fushi/src/media/acquisition/media_acquisition_backends.dart';
import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/pages/implementations/ai_media_acquisition_page.dart';
import 'package:fushi/utils.dart';

class _FakeBackend implements MediaAcquisitionBackend {
  final List<String> searched = <String>[];
  final List<String> acquired = <String>[];

  @override
  Future<List<MediaAcquisitionCandidate>> search(String query) async {
    searched.add(query);
    return <MediaAcquisitionCandidate>[
      for (int i = 0; i < 3; i++)
        MediaAcquisitionCandidate(
          id: 'c$i',
          title: '$query result $i',
          sourceLabel: 'Src',
          backend: this,
          payload: i,
          score: i,
        ),
    ];
  }

  /// 下一次 [acquire] 的结果（缺省：已开始）。
  DownloadStartResult result = const DownloadStartResult.started();

  @override
  Future<DownloadStartResult> acquire(
    BuildContext context,
    MediaAcquisitionCandidate candidate,
  ) async {
    acquired.add(candidate.id);
    return result;
  }
}

Widget _host(AiMediaAcquisitionPage page) =>
    TranslationProvider(child: MaterialApp(home: page));

void main() {
  test('候选排序：AI 推荐在前按推荐序，其余按本地分降序', () {
    final _FakeBackend backend = _FakeBackend();
    MediaAcquisitionCandidate c(String id, int score) =>
        MediaAcquisitionCandidate(
          id: id,
          title: id,
          sourceLabel: 's',
          backend: backend,
          payload: id,
          score: score,
        );
    final List<MediaAcquisitionCandidate> ordered =
        orderMediaAcquisitionCandidates(
          <MediaAcquisitionCandidate>[
            c('a', 1),
            c('b', 5),
            c('c', 3),
            c('d', 9),
          ],
          <String>['c', 'missing', 'a'],
        );
    expect(ordered.map((MediaAcquisitionCandidate x) => x.id), <String>[
      'c',
      'a',
      'd',
      'b',
    ]);
  });

  testWidgets('一句话 → AI 搜索词 → 搜 → AI 推荐 → 用户点下载', (WidgetTester tester) async {
    final _FakeBackend backend = _FakeBackend();
    final List<String> pickPool = <String>[];
    await tester.pumpWidget(
      _host(
        AiMediaAcquisitionPage(
          domain: AiMediaAcquisitionDomain.game,
          domainLabel: 'Games',
          initialQuery: '帮我下 サクラノ詩',
          backends: <MediaAcquisitionBackend>[backend],
          ai: AiMediaAcquisitionAi(
            parseIntent: (AiMediaAcquisitionDomain _, String __) async =>
                const AiMediaAcquisitionIntent(queries: <String>['サクラノ詩']),
            pick:
                (
                  AiMediaAcquisitionDomain _,
                  String __,
                  List<AiMediaAcquisitionCandidateFact> facts,
                ) async {
                  pickPool.addAll(
                    facts.map((AiMediaAcquisitionCandidateFact f) => f.id),
                  );
                  return <String>['c1'];
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.searched, <String>['サクラノ詩'], reason: '按 AI 解析出的词搜，不按原句');
    expect(pickPool, <String>['c2', 'c1', 'c0'], reason: '挑选池按本地分排好');
    expect(find.text(t.ai_media_acquire_recommended), findsOneWidget);
    // 推荐项排第一，且是唯一的实心「下载」按钮；AI 不自己触发下载。
    expect(backend.acquired, isEmpty);
    final Finder recommended = find.byKey(
      const ValueKey<String>('ai-media-acquire-candidate-c1'),
    );
    expect(recommended, findsOneWidget);
    await tester.tap(
      find.descendant(of: recommended, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();
    expect(backend.acquired, <String>['c1']);
    expect(
      find.descendant(
        of: recommended,
        matching: find.byIcon(FushiIcons.filled(FushiIcons.success)),
      ),
      findsOneWidget,
    );
  });

  // 后端不再自己 toast：页面按结果显示提示，失败的候选不标成「已开始」。
  testWidgets('下载失败：页面显示后端给的原因，不标已开始', (WidgetTester tester) async {
    final _FakeBackend backend = _FakeBackend()
      ..result = const DownloadStartResult.failed(<DownloadStartNotice>[
        DownloadStartNotice.error('源站要求登录'),
      ]);
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navigatorKey;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: AiMediaAcquisitionPage(
            domain: AiMediaAcquisitionDomain.manga,
            domainLabel: 'Manga',
            initialQuery: 'x',
            backends: <MediaAcquisitionBackend>[backend],
            ai: AiMediaAcquisitionAi(
              parseIntent: (AiMediaAcquisitionDomain _, String __) async =>
                  null,
              pick:
                  (
                    AiMediaAcquisitionDomain _,
                    String __,
                    List<AiMediaAcquisitionCandidateFact> ___,
                  ) async => <String>['c0'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder row = find.byKey(
      const ValueKey<String>('ai-media-acquire-candidate-c0'),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byType(FilledButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.acquired, <String>['c0']);
    expect(find.text('源站要求登录'), findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(FushiIcons.filled(FushiIcons.success)),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('AI 两步都失败：按原文搜、按本地分列出并提示降级', (WidgetTester tester) async {
    final _FakeBackend backend = _FakeBackend();
    await tester.pumpWidget(
      _host(
        AiMediaAcquisitionPage(
          domain: AiMediaAcquisitionDomain.novel,
          domainLabel: 'Books',
          initialQuery: 'raw text',
          backends: <MediaAcquisitionBackend>[backend],
          ai: AiMediaAcquisitionAi(
            parseIntent: (AiMediaAcquisitionDomain _, String __) async =>
                throw StateError('down'),
            pick:
                (
                  AiMediaAcquisitionDomain _,
                  String __,
                  List<AiMediaAcquisitionCandidateFact> ___,
                ) async => throw StateError('down'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(backend.searched, <String>['raw text']);
    expect(
      find.byKey(const ValueKey<String>('ai-media-acquire-degraded')),
      findsOneWidget,
    );
    expect(find.text(t.ai_media_acquire_recommended), findsNothing);
    expect(find.text('raw text result 2'), findsOneWidget);
  });
}
