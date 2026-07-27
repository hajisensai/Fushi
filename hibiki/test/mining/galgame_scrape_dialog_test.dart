import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/mining/galgame_scrape_controller.dart';
import 'package:hibiki/src/mining/galgame_scrape_dialog.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';
import 'package:hibiki/utils.dart';

/// 统一刮削弹窗守卫（对齐视频 cover_match_dialog 的单弹窗闭环）：
/// 1. 打开即按预填词自动首搜，候选带「源 · ID · 发行日」副行与每行「使用」按钮；
/// 2. 点「使用」→ fetchById 补全 → saveScrapeResult 真写穿 DB（primarySource
///    单源记该源 key），弹窗以 true 关闭；
/// 3. 空结果给弹窗内空态（可改词重试），全源失败给错误行且重搜可恢复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<(GalgameRepository, GalgameEntry)> buildRepo() async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final GalgameRepository repo = GalgameRepository(db);
    final GalgameEntry entry = GalgameEntry(
      id: 'g1',
      name: 'alpha',
      exePath: r'Z:\a\alpha.exe',
      workdir: r'Z:\a',
      addedAt: DateTime(2026),
    );
    await repo.addAll(<GalgameEntry>[entry]);
    return (repo, repo.byId('g1')!);
  }

  Future<Future<bool?> Function()> pumpDialogOpener(
    WidgetTester tester, {
    required GalgameRepository repo,
    required GalgameEntry game,
    required GalgameScrapeController controller,
  }) async {
    Future<bool?>? result;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () {
                  result = showAppDialog<bool>(
                    context: ctx,
                    builder: (_) => GalgameScrapeDialog(
                      game: game,
                      repo: repo,
                      controllerOverride: controller,
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
    return () => result ?? Future<bool?>.value();
  }

  testWidgets('打开即自动首搜；点「使用」落库 primarySource 并以 true 关闭',
      (WidgetTester tester) async {
    final (GalgameRepository repo, GalgameEntry game) = await buildRepo();
    final _FakeAdapter bgm = _FakeAdapter(GalgameMetadataSource.bgm)
      ..results = const <SourceCandidate>[
        SourceCandidate(
          source: GalgameMetadataSource.bgm,
          externalId: '4885',
          name: 'alpha',
          nameCn: '阿尔法物语',
          releaseDate: '2024-03-15',
        ),
      ]
      ..draft = const GalgameMetadataDraft(
        name: 'alpha',
        nameCn: '阿尔法物语',
        summary: '简介',
        externalId: '4885',
      );
    final GalgameScrapeController controller =
        GalgameScrapeController(adapters: <GalgameMetadataAdapter>[bgm]);
    final Future<bool?> Function() applied = await pumpDialogOpener(
      tester,
      repo: repo,
      game: game,
      controller: controller,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 自动首搜已按显示名跑过一次并渲染候选（无需手点搜索）。
    expect(bgm.searchedNames, <String>['alpha']);
    expect(find.text('阿尔法物语'), findsOneWidget);
    // 副行：源 label · externalId · releaseDate。
    expect(
      find.text('Bangumi · 4885 · 2024-03-15'),
      findsOneWidget,
      reason: '候选副行必须是「源 · ID · 发行日」',
    );

    await tester.tap(find.text(t.game_scrape_use));
    await tester.pumpAndSettle();

    // 真写穿 DB：源快照 + 单源 primarySource 记该源 key。
    final GalgameEntry saved = repo.byId('g1')!;
    expect(saved.primarySource, GalgameMetadataSource.bgm.key);
    expect(saved.displayName, '阿尔法物语');
    final List<GalgameSourceRow> sources = await repo.sourcesOf('g1');
    expect(sources, hasLength(1));
    expect(sources.single.externalId, '4885');
    // 弹窗以 true 关闭（调用方据此刷新）。
    expect(await applied(), isTrue);
    expect(find.byType(GalgameScrapeDialog), findsNothing);
    await tester.pump(const Duration(seconds: 4)); // 放掉桌面 toast 计时器
  });

  testWidgets('已有可用封面时点「使用」不碰网络、不覆盖封面（游戏岛封面纪律）', (WidgetTester tester) async {
    // 回归守卫：本弹窗曾把「使用」改成无条件下载并覆盖 coverPath，直接
    // 盖掉用户手选的封面（游戏岛无 CoverOrigin 保护、无确认、无备份、不可撤销），
    // 与 media_cover_service.dart 的封面纪律表直接矛盾。
    //
    // “没覆盖”光看 coverPath 不算数——下载失败也会保留旧值。这里把 HttpClient
    // 构造堆成地雷（[_ExplodingHttpOverrides]）：只要走到下载就抛，落库会被弹窗
    // 的 catch 接住→弹窗不关。因此「弹窗以 true 关闭」= 一次网络都没发。
    final HttpOverrides? previous = HttpOverrides.current;
    HttpOverrides.global = _ExplodingHttpOverrides();
    addTearDown(() => HttpOverrides.global = previous);

    final Directory dir = Directory.systemTemp.createTempSync('gal_cover_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File cover = File('${dir.path}/manual.png')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final (GalgameRepository repo, GalgameEntry game) = await buildRepo();
    await repo.setCoverPath('g1', cover.path);

    const String url = 'https://example.invalid/should-not-be-fetched.jpg';
    final _FakeAdapter bgm = _FakeAdapter(GalgameMetadataSource.bgm)
      ..results = const <SourceCandidate>[
        SourceCandidate(
          source: GalgameMetadataSource.bgm,
          externalId: '4885',
          coverUrl: url,
        ),
      ]
      ..draft = const GalgameMetadataDraft(
        name: 'alpha',
        externalId: '4885',
        coverUrl: url,
      );
    final GalgameScrapeController controller =
        GalgameScrapeController(adapters: <GalgameMetadataAdapter>[bgm]);
    final Future<bool?> Function() applied = await pumpDialogOpener(
      tester,
      repo: repo,
      game: repo.byId('g1')!,
      controller: controller,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.game_scrape_use));
    await tester.pumpAndSettle();

    // 元数据落了、弹窗正常关闭（= 没碰网络）、封面原封不动。
    expect(await repo.sourcesOf('g1'), hasLength(1));
    expect(
      find.byType(GalgameScrapeDialog),
      findsNothing,
      reason: '已有可用封面时不得发封面下载请求（发了就会抛、弹窗不会关）。',
    );
    expect(await applied(), isTrue);
    expect(
      repo.byId('g1')!.coverPath,
      cover.path,
      reason: '刷削绝不得覆盖用户已有的封面文件。',
    );
    expect(cover.readAsBytesSync(), <int>[1, 2, 3]);
    await tester.pump(const Duration(seconds: 4)); // 放掉桌面 toast 计时器
  });

  testWidgets('已有他源快照时落库 primarySource 记 mixed', (WidgetTester tester) async {
    final (GalgameRepository repo, GalgameEntry game) = await buildRepo();
    // 预置一份 vndb 快照：再落 bgm 就是多源。
    await repo.saveScrapeResult(
      gameId: 'g1',
      source: GalgameMetadataSource.vndb,
      draft: const GalgameMetadataDraft(name: 'alpha', externalId: 'v99'),
      primarySource: GalgameMetadataSource.vndb.key,
    );
    final _FakeAdapter bgm = _FakeAdapter(GalgameMetadataSource.bgm)
      ..results = const <SourceCandidate>[
        SourceCandidate(source: GalgameMetadataSource.bgm, externalId: '4885'),
      ]
      ..draft = const GalgameMetadataDraft(name: 'alpha', externalId: '4885');
    final GalgameScrapeController controller =
        GalgameScrapeController(adapters: <GalgameMetadataAdapter>[bgm]);
    await pumpDialogOpener(
      tester,
      repo: repo,
      game: game,
      controller: controller,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.game_scrape_use));
    await tester.pumpAndSettle();

    expect(repo.byId('g1')!.primarySource, kGalgamePrimarySourceMixed);
    expect(await repo.sourcesOf('g1'), hasLength(2));
    await tester.pump(const Duration(seconds: 4)); // 放掉桌面 toast 计时器
  });

  testWidgets('空结果给弹窗内空态（不再 toast 后散场）', (WidgetTester tester) async {
    final (GalgameRepository repo, GalgameEntry game) = await buildRepo();
    final _FakeAdapter bgm = _FakeAdapter(GalgameMetadataSource.bgm);
    final GalgameScrapeController controller =
        GalgameScrapeController(adapters: <GalgameMetadataAdapter>[bgm]);
    await pumpDialogOpener(
      tester,
      repo: repo,
      game: game,
      controller: controller,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(GalgameScrapeDialog), findsOneWidget);
    expect(find.text(t.game_scrape_no_result), findsOneWidget);
    // 弹窗仍在：搜索框可改词重试。
    expect(find.byType(TextField), findsOneWidget);
  });

  group('normalizeGalgameScrapeQuery（贴条目 URL 归一成源裸 ID）', () {
    test('Bangumi 条目 URL（三个域名）→ 数字裸 ID', () {
      expect(
        normalizeGalgameScrapeQuery('https://bgm.tv/subject/4885'),
        '4885',
      );
      expect(
        normalizeGalgameScrapeQuery('https://bangumi.tv/subject/4885/'),
        '4885',
      );
      expect(
        normalizeGalgameScrapeQuery('http://chii.in/subject/4885'),
        '4885',
      );
      expect(
        normalizeGalgameScrapeQuery('https://www.bgm.tv/subject/4885'),
        '4885',
      );
    });

    test('带 query / fragment / 多余路径段照样归一', () {
      expect(
        normalizeGalgameScrapeQuery(
          'https://bgm.tv/subject/4885?tab=comments#top',
        ),
        '4885',
      );
      expect(
        normalizeGalgameScrapeQuery('https://bgm.tv/subject/4885/comments'),
        '4885',
      );
      expect(
        normalizeGalgameScrapeQuery('https://vndb.org/v17/chars?f=x#y'),
        'v17',
      );
    });

    test('VNDB 条目 URL → v<数字>（允许尾随斜杠/多余路径段）', () {
      expect(normalizeGalgameScrapeQuery('https://vndb.org/v17'), 'v17');
      expect(normalizeGalgameScrapeQuery('https://vndb.org/v17/'), 'v17');
      expect(normalizeGalgameScrapeQuery('https://vndb.org/V17'), 'v17');
    });

    test('丢协议的地址栏复制形态（bgm.tv/subject/…）也认', () {
      expect(normalizeGalgameScrapeQuery('bgm.tv/subject/4885'), '4885');
      expect(normalizeGalgameScrapeQuery('vndb.org/v17'), 'v17');
    });

    test('非条目 URL 原样透传', () {
      expect(
        normalizeGalgameScrapeQuery('https://bgm.tv/user/foo'),
        'https://bgm.tv/user/foo',
      );
      expect(
        normalizeGalgameScrapeQuery('https://vndb.org/g123'),
        'https://vndb.org/g123',
      );
      // 域名不认识：即使路径形似 subject 也不动。
      expect(
        normalizeGalgameScrapeQuery('https://example.com/subject/4885'),
        'https://example.com/subject/4885',
      );
      // subject 后不是纯数字：不动。
      expect(
        normalizeGalgameScrapeQuery('https://bgm.tv/subject/abc'),
        'https://bgm.tv/subject/abc',
      );
    });

    test('裸词 / 裸 ID 零行为变化', () {
      expect(normalizeGalgameScrapeQuery('clannad'), 'clannad');
      expect(normalizeGalgameScrapeQuery('4885'), '4885');
      expect(normalizeGalgameScrapeQuery('v17'), 'v17');
      expect(normalizeGalgameScrapeQuery('CLANNAD 完整版'), 'CLANNAD 完整版');
      expect(normalizeGalgameScrapeQuery(''), '');
    });
  });

  testWidgets('全源失败给错误行，改好后重搜可恢复', (WidgetTester tester) async {
    final (GalgameRepository repo, GalgameEntry game) = await buildRepo();
    final _FakeAdapter bgm = _FakeAdapter(GalgameMetadataSource.bgm)
      ..failSearch = true;
    final GalgameScrapeController controller =
        GalgameScrapeController(adapters: <GalgameMetadataAdapter>[bgm]);
    await pumpDialogOpener(
      tester,
      repo: repo,
      game: game,
      controller: controller,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 全源失败：错误行（区别于空态），不是静默空列表。
    expect(find.text(t.game_scrape_search_failed), findsOneWidget);
    expect(find.text(t.game_scrape_no_result), findsNothing);

    // 网络恢复后点「搜索」重试即出候选。
    bgm
      ..failSearch = false
      ..results = const <SourceCandidate>[
        SourceCandidate(
          source: GalgameMetadataSource.bgm,
          externalId: '4885',
          name: 'alpha',
        ),
      ];
    await tester.tap(find.text(t.game_scrape_search));
    await tester.pumpAndSettle();
    expect(find.text(t.game_scrape_search_failed), findsNothing);
    expect(find.text(t.game_scrape_use), findsOneWidget);
  });
}

/// 可控假 adapter：searchByName / fetchById 的结果与失败全由测试摆布。
class _FakeAdapter implements GalgameMetadataAdapter {
  _FakeAdapter(this.source);

  @override
  final GalgameMetadataSource source;

  List<SourceCandidate> results = const <SourceCandidate>[];
  GalgameMetadataDraft? draft;
  bool failSearch = false;

  /// 收到过的搜索词（断言自动首搜用）。
  final List<String> searchedNames = <String>[];

  @override
  bool validateId(String id) => false;

  @override
  String externalUrl(String id) => 'https://example.com/$id';

  @override
  Future<GalgameMetadataDraft?> fetchById(String id) async => draft;

  @override
  Future<List<SourceCandidate>> searchByName(String name, {int? limit}) async {
    searchedNames.add(name);
    if (failSearch) {
      throw const GalgameMetadataException('boom', source: null);
    }
    return results;
  }

  @override
  void close() {}
}

/// 构造 HttpClient 即抛：用来证明某条路径**一次网络都没发**（比断言结果没变强，
/// 后者被「下载失败也保留旧值」掩盖）。
class _ExplodingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw StateError('unexpected network access');
  }
}
