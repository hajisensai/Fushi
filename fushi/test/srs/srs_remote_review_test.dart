// 远程复习（docs/specs/2026-11-01-srs-remote-review-design.md）的客户端端到端：
// SrsRemoteStore → MockClient → 真实的 `/api/srs/remote/*` 路由 → SrsRemoteStoreService → 内存库上的 SrsDbStore。
//
// - 远程库读到的卡片详情 / 卡面 / 笔记类型与主机库直接读到的相同；笔记类型按标签缓存，只搬一次；
// - 卡片 / 笔记操作、扩展流程（按类型列笔记、更改笔记类型预演、修改历史）都落在主机库上；
// - 回包丢了用同一请求 id 重发：只记一条日志；出卡后卡在主机上被复习过：作答回 stale；
// - 媒体按名字拉进缓存，同名只拉一次，非法名字不发请求；
// - 本机同一个 SrsReviewPage 跑在远程作用域里：键盘翻面 → 评分 → 下一张 → Ctrl+Z 撤销，日志写在主机库。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_remote_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

const FushiClientUrl _peer = FushiClientUrl(
  url: 'http://host:8765',
  token: 'tok',
  hostId: 'host-1',
);

/// 一台互联主机：内存库上的复习 + 远程复习库服务；[client] 经 MockClient 打到真实路由。
class _Host {
  _Host(this.db, this.store);

  final FushiDatabase db;
  final SrsDbStore store;
  late final SrsRemoteStoreService service = SrsRemoteStoreService(
    readStore: () async => store,
    readMedia: (String name) async => media[name],
    onWrite: () => writes++,
  );

  int writes = 0;

  /// 作答请求「主机处理完、回包丢了」的次数（> 0 时下一次作答回包丢掉）。
  int dropAnswerResponses = 0;

  /// 为 true 时 deckSummaries 回一个不合契约的包（result 不是列表）。
  bool malformedDeckSummaries = false;

  /// 收到的操作名（媒体请求记成 `media/<名字>`）。
  final List<String> ops = <String>[];
  final Map<String, Uint8List> media = <String, Uint8List>{};

  late final SyncRepository repository = SyncRepository(db);

  SrsRemoteHostClient client() => SrsRemoteHostClient(
    repository: repository,
    peer: _peer,
    httpClient: MockClient((http.Request r) async {
      final String path = r.url.path;
      if (!path.startsWith(kSrsRemoteStorePathPrefix)) {
        return http.Response('', 404);
      }
      String? op;
      if (r.method == 'POST') {
        op = (jsonDecode(r.body) as Map)['op'] as String?;
        ops.add(op!);
      } else {
        ops.add(path.substring(kSrsRemoteStorePathPrefix.length));
      }
      if (op == 'deckSummaries' && malformedDeckSummaries) {
        return http.Response(
          jsonEncode(<String, Object?>{'result': 5}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      final shelf.Response res = await handleSrsRemoteStoreRequest(
        service,
        shelf.Request(
          r.method,
          Uri.parse('http://host$path'),
          body: r.method == 'GET' ? null : r.body,
        ),
        r.method,
        path,
      );
      final List<int> bytes = <int>[
        for (final List<int> chunk in await res.read().toList()) ...chunk,
      ];
      if (op == 'answerAndStudy' && dropAnswerResponses > 0) {
        dropAnswerResponses--;
        throw const SocketException('response lost');
      }
      return http.Response.bytes(bytes, res.statusCode, headers: res.headers);
    }),
  );

  Future<SrsRemoteStore> remote() => SrsRemoteStore.connect(client());
}

Future<_Host> _openHost(List<String> expressions) async {
  final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
  for (int i = 0; i < expressions.length; i++) {
    await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      createdAt: 1700000000000 + i,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expressions[i],
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'):
            'def-${expressions[i]}',
      },
    );
  }
  await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[_peer]);
  return _Host(db, store);
}

/// 首页「已配对设备」用的连接器：只有 [host] 一台主机，连它走 MockClient。
class _FakeConnector extends SrsRemoteHostConnector {
  const _FakeConnector(super.app, this.host, this.dir);

  final _Host host;
  final Directory dir;

  @override
  Future<List<InterconnectHostTarget>> probe() async =>
      const <InterconnectHostTarget>[
        InterconnectHostTarget(
          hostId: 'host-1',
          displayName: 'Host',
          peer: _peer,
        ),
      ];

  @override
  Future<SrsRemoteSession> open(InterconnectHostTarget target) async {
    final SrsRemoteHostClient client = host.client();
    final SrsRemoteMediaStore media = SrsRemoteMediaStore(dir, client);
    final SrsRemoteStore store = await SrsRemoteStore.connect(
      client,
      prefetchMedia: media.prefetch,
    );
    return SrsRemoteSession(client: client, store: store, media: media);
  }
}

/// 记下探测 / 握手次数的连接器。
class _CountingConnector extends _FakeConnector {
  _CountingConnector(super.app, super.host, super.dir);

  int probes = 0;
  int opens = 0;

  @override
  Future<List<InterconnectHostTarget>> probe() {
    probes++;
    return super.probe();
  }

  @override
  Future<SrsRemoteSession> open(InterconnectHostTarget target) {
    opens++;
    return super.open(target);
  }
}

/// 首页（手机宽度：牌组行是窄屏排法，长按出菜单；高度放得下整页，懒列表把分区建出来）。
Future<void> _pumpHome(
  WidgetTester tester, {
  required AppModel app,
  required SrsDbStore local,
  List<Override> overrides = const <Override>[],
  GlobalKey<NavigatorState>? nav,
  Widget home = const SrsDeckListPage(),
}) async {
  tester.view.physicalSize = const Size(412, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) async => local),
        srsRwkvServiceProvider.overrideWith((Ref ref) async => null),
        ...overrides,
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: nav,
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: home,
        ),
      ),
    ),
  );
}

void main() {
  test('卡面引用的媒体名：[sound:]、src / poster、CSS url，只认裸文件名', () {
    expect(
      srsCardReferencedMedia(
        '[sound:a.mp3]<img src="b.png"><video poster=\'c.jpg\'>'
        '<img src="https://x/y.png"><img src="/abs.png">'
        '<style>.x{background:url("d.webp")}</style>'
        '<img src="e&amp;f.png">',
      ),
      <String>{'a.mp3', 'b.png', 'c.jpg', 'd.webp', 'e&f.png'},
    );
  });

  group('远程库 ↔ 主机', () {
    late _Host host;
    setUp(() async {
      host = await _openHost(<String>['犬', '猫', '鳥']);
    });
    tearDown(() => host.db.close());

    test('读到的与主机库相同；笔记类型按标签缓存只搬一次', () async {
      final SrsRemoteStore remote = await host.remote();
      expect(remote.profileUid, host.store.profileUid);
      expect(remote.defaultDeckId, host.store.defaultDeckId);
      final String deck = host.store.defaultDeckId;
      final SrsStudyState study = (await remote.studyState(deck))!;
      final SrsStudyState hostStudy = (await host.store.studyState(deck))!;
      expect(study.next, hostStudy.next);
      expect(study.summary.newCount, hostStudy.summary.newCount);

      final String card = study.next!;
      final SrsCardDetail detail = (await remote.cardDetail(card))!;
      final SrsCardDetail hostDetail = (await host.store.cardDetail(card))!;
      expect(detail.card, hostDetail.card);
      expect(detail.note.fields, hostDetail.note.fields);
      expect(detail.noteType.name, hostDetail.noteType.name);
      expect(detail.template?.id, hostDetail.template?.id);
      expect(detail.deckName, hostDetail.deckName);
      final SrsRenderedCard rendered = (await remote.renderCard(card))!;
      expect(rendered.question, (await host.store.renderCard(card))!.question);

      await remote.cardDetail(study.after!);
      expect(
        host.ops.where((String o) => o == 'noteTypeSources'),
        hasLength(1),
        reason: '同一笔记类型标签没变不再搬',
      );
      expect(
        (await remote.noteTypes()).map((SrsNoteTypeView t) => t.id),
        (await host.store.noteTypes()).map((SrsNoteTypeView t) => t.id),
      );
      expect(
        await remote.noteIdsOfType(host.store.lapisNoteTypeId),
        await host.store.noteIdsOfType(host.store.lapisNoteTypeId),
      );
    });

    test('卡片 / 笔记操作与扩展流程落在主机库上', () async {
      final SrsRemoteStore remote = await host.remote();
      final String card = (await remote.studyState(
        host.store.defaultDeckId,
      ))!.next!;
      final SrsCardDetail detail = (await remote.cardDetail(card))!;
      final String note = detail.note.id;

      await remote.setFlag(card, 3);
      await remote.setSuspended(card, true);
      SrsCardCacheRow row = (await host.store.cardRow(card))!;
      expect(row.flag, 3);
      expect(row.suspended, isTrue);
      await remote.setSuspended(card, false);

      final String exprId = srsLapisFieldId(kSrsTestProfile, 'Expression');
      await remote.updateNote(
        note,
        fieldsById: <String, String>{exprId: '狐'},
        tags: <String>['remote'],
      );
      SrsNoteView hostNote = (await host.store.note(note))!;
      expect(hostNote.field(exprId), '狐');
      expect(hostNote.tags, <String>['remote']);

      final List<SrsHistoryEntry> edits = await remote.editHistory(
        SrsEntityKind.note,
        note,
      );
      expect(
        edits.map((SrsHistoryEntry e) => e.key),
        containsAll(<String>[SrsFieldKeys.noteField(exprId), 'tags']),
      );

      await remote.deleteNote(note);
      expect((await host.store.note(note))!.deletedAt, isNotNull);
      await remote.restoreNote(note);
      hostNote = (await host.store.note(note))!;
      expect(hostNote.deletedAt, isNull);

      final ({int newCards, int reviews}) ext = await remote.extendTodayLimits(
        host.store.defaultDeckId,
        newCards: 5,
      );
      expect(ext.newCards, 5);

      final SrsNoteTypeChangePreview preview = await remote
          .previewNoteTypeChange(
            noteIds: <String>[note],
            targetTypeId: host.store.lapisNoteTypeId,
            fieldMap: const <String, String?>{},
            templateMap: const <String, String?>{},
          );
      expect(preview.from.id, host.store.lapisNoteTypeId);
      expect(preview.plans, hasLength(1));
      row = (await host.store.cardRow(card))!;
      expect(row.suspended, isFalse);
      expect(host.writes, greaterThanOrEqualTo(7));
    });

    test('回包丢了用同一请求 id 重发：只记一条日志', () async {
      final SrsRemoteStore remote = await host.remote();
      final String deck = host.store.defaultDeckId;
      final String card = (await remote.studyState(deck))!.next!;
      await remote.cardDetail(card);
      host.dropAnswerResponses = 1;
      final SrsAnswerOutcome out = await remote.answerAndStudy(
        card,
        3,
        durationMs: 1200,
        studyDeckId: deck,
      );
      final SrsCardHistory history = await host.store.history(card);
      expect(history.all, hasLength(1));
      expect(history.all.single.id, out.log.id);
      expect(host.ops.where((String o) => o == 'answerAndStudy'), hasLength(2));
      expect(out.study?.next, isNot(card));
    });

    test('出卡后卡在主机上被复习过：作答报卡已变，不记日志；重新出题后能正常作答', () async {
      final SrsRemoteStore remote = await host.remote();
      final String deck = host.store.defaultDeckId;
      final String card = (await remote.studyState(deck))!.next!;
      await remote.cardDetail(card);
      await host.store.answer(card, 4);
      await expectLater(
        remote.answerAndStudy(card, 1, durationMs: 1000, studyDeckId: deck),
        throwsA(
          isA<SrsCardChangedError>().having(
            (SrsCardChangedError e) => e.cardId,
            'cardId',
            card,
          ),
        ),
      );
      expect((await host.store.history(card)).all, hasLength(1));
      // 基线已作废：重新出这张卡后作答照常落库，不会一直 stale。
      await remote.cardDetail(card);
      await remote.answerAndStudy(card, 3, durationMs: 1000, studyDeckId: deck);
      expect((await host.store.history(card)).all, hasLength(2));
    });

    test('媒体缓存：缺的按名字拉一次，之后读本地；非法名字不发请求', () async {
      host.media['a.png'] = Uint8List.fromList(<int>[1, 2, 3]);
      final Directory dir = Directory.systemTemp.createTempSync('srs_rm_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final SrsRemoteMediaStore store = SrsRemoteMediaStore(dir, host.client());
      await Future.wait(<Future<bool>>[
        store.fetch('a.png'),
        store.fetch('a.png'),
      ]);
      expect(await store.load('a.png'), <int>[1, 2, 3]);
      expect(await store.load('missing.png'), isNull);
      expect(await store.load('../evil.png'), isNull);
      expect(host.ops.where((String o) => o == 'media/a.png'), hasLength(1));
      expect(host.ops.where((String o) => o.contains('evil')), isEmpty);
    });
  });

  group('页面', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
      for (int i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('本机的复习页跑在主机的库上：翻面 → 评分 → 下一张 → 撤销', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Host host = (await tester.runAsync(
        () => _openHost(<String>['犬', '猫']),
      ))!;
      addTearDown(() => tester.runAsync(host.db.close));
      final Directory dir = Directory.systemTemp.createTempSync('srs_rp_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final SrsRemoteHostClient client = host.client();
      final SrsRemoteMediaStore media = SrsRemoteMediaStore(dir, client);
      final SrsRemoteStore remote = (await tester.runAsync(
        () => SrsRemoteStore.connect(client, prefetchMedia: media.prefetch),
      ))!;
      final AppModel app = AppModel(testPlatformServices())
        ..shortcutRegistry.loadDefaults(TargetPlatform.windows);
      final List<SrsCardFace> faces = <SrsCardFace>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => app),
            srsCardFaceBuilderProvider.overrideWithValue((
              BuildContext context,
              SrsCardFace face,
            ) {
              faces.add(face);
              return SrsPlainCardFace(face: face);
            }),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              theme: buildFushiThemeData(
                scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
                textTheme: Typography.material2021().black,
                designSystem: FushiDesignSystem.material,
                glass: FushiGlassMaterial.off,
                glassDesign: false,
              ),
              builder: (BuildContext context, Widget? child) =>
                  FushiGlassScope(child: child!),
              home: SrsRemoteCollectionScope(
                store: remote,
                media: media,
                child: SrsReviewPage(
                  deckId: remote.defaultDeckId,
                  deckName: 'Default',
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(faces, isNotEmpty);
      final String first = faces.last.cardId;
      expect(faces.last.showingAnswer, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester, rounds: 6);
      expect(faces.last.cardId, first);
      expect(faces.last.showingAnswer, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await settle(tester);
      expect(faces.last.cardId, isNot(first), reason: '评分后换到下一张');
      final SrsCardHistory afterRate = (await tester.runAsync(
        () => host.store.history(first),
      ))!;
      expect(afterRate.all, hasLength(1), reason: '评分记在主机库');
      expect(afterRate.all.single.rating, 3);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(faces.last.cardId, first, reason: '撤销带回上一张');
      final SrsCardHistory afterUndo = (await tester.runAsync(
        () => host.store.history(first),
      ))!;
      expect(afterUndo.lastEffective, isNull, reason: '主机库上的评分已撤销');
      expect(host.ops, contains('undo'));

      // 出题之后这张卡在主机上被复习了：作答不记、跳过它，不卡在这张上。
      await tester.runAsync(() => host.store.answer(first, 4));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester, rounds: 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await settle(tester);
      expect(faces.last.cardId, isNot(first), reason: '卡已变：跳过重排');
      final SrsCardHistory afterStale = (await tester.runAsync(
        () => host.store.history(first),
      ))!;
      expect(afterStale.lastEffective?.rating, 4, reason: '这次评分没记');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    // 远程牌组列表压出的页面（复习 / 浏览 / 牌组设置 / 添加笔记）必须沿用远程作用域：路由建在导航器的
    // overlay 里，不经 srsPushPage 就会落回根作用域、读写本机库（PR #2767 审查的阻断项）。
    testWidgets('复习首页「已配对设备」：主机牌组是树（缩进、可折叠），复习 / 浏览 / 牌组设置 / 添加笔记都读写主机的库', (
      WidgetTester tester,
    ) async {
      final _Host host = (await tester.runAsync(
        () => _openHost(<String>['犬', '猫']),
      ))!;
      addTearDown(() => tester.runAsync(host.db.close));
      final (String parentId, String childId) = (await tester.runAsync(
        () async {
          final String parent = await host.store.createDeck('Parent');
          final String child = await host.store.createDeck(
            'Child',
            parentId: parent,
          );
          return (parent, child);
        },
      ))!;
      // 根作用域里另有一份本机库（同一 profile、同 ID 的默认牌组，但没有卡）：页面若落回根作用域会读写它。
      final (FushiDatabase localDb, SrsDbStore local) = (await tester.runAsync(
        () => openSrsTestStore(deviceId: 'local'),
      ))!;
      addTearDown(() => tester.runAsync(localDb.close));
      final Directory dir = Directory.systemTemp.createTempSync('srs_rd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final int localRevision = local.revision;
      final AppModel app = SrsTestAppModel();
      final List<SrsCardFace> faces = <SrsCardFace>[];
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await _pumpHome(
        tester,
        app: app,
        local: local,
        nav: nav,
        overrides: <Override>[
          srsRemoteHostConnectorProvider.overrideWithValue(
            _FakeConnector(app, host, dir),
          ),
          srsCardFaceBuilderProvider.overrideWithValue((
            BuildContext context,
            SrsCardFace face,
          ) {
            faces.add(face);
            return SrsPlainCardFace(face: face);
          }),
        ],
      );
      await settle(tester);

      expect(
        find.byKey(const ValueKey<String>('srs-home-paired')),
        findsOneWidget,
        reason: '有可用主机：首页出现「已配对设备」分区',
      );
      final Finder header = find.byKey(
        const ValueKey<String>('srs-paired-header-host-1'),
      );
      expect(
        find.descendant(of: header, matching: find.text('Host')),
        findsOneWidget,
      );
      Finder inRow(String deckId, Finder matching) => find.descendant(
        of: find.byKey(ValueKey<String>('srs-paired-deck-host-1-$deckId')),
        matching: matching,
      );
      expect(
        inRow(parentId, find.text('Parent')),
        findsNothing,
        reason: '组默认收起',
      );

      // 展开：主机的牌组按树画，子牌组带层级竖线，父牌组能收起 / 展开子牌组。
      await tester.tap(header);
      await settle(tester);
      expect(inRow(parentId, find.text('Parent')), findsOneWidget);
      expect(inRow(childId, find.text('Child')), findsOneWidget);
      expect(
        inRow(
          childId,
          find.byKey(ValueKey<String>('srs-deck-indent-$childId')),
        ),
        findsOneWidget,
        reason: '子牌组带层级缩进（树），不是平铺',
      );
      final Finder toggle = inRow(
        parentId,
        find.byKey(ValueKey<String>('srs-deck-toggle-$parentId')),
      );
      await tester.tap(toggle);
      await settle(tester);
      expect(inRow(childId, find.text('Child')), findsNothing, reason: '收起父牌组');
      await tester.tap(toggle);
      await settle(tester);
      expect(inRow(childId, find.text('Child')), findsOneWidget, reason: '再展开');

      /// 压出的页面打开期间主机收到的操作（页面经远程库读数据才会有）。
      Future<List<String>> opsWhileOpen(Future<void> Function() open) async {
        final int before = host.ops.length;
        await open();
        await settle(tester);
        final List<String> during = host.ops.sublist(before);
        nav.currentState!.pop();
        await settle(tester);
        return during;
      }

      // 复习：点主机默认牌组的播放 → 出的是主机的卡，评分记在主机库。
      final String deckId = local.defaultDeckId;
      await tester.tap(
        inRow(deckId, find.byKey(ValueKey<String>('srs-deck-review-$deckId'))),
      );
      await settle(tester);
      expect(find.byType(SrsReviewPage), findsOneWidget);
      expect(faces, isNotEmpty, reason: '复习页读到的是主机库的卡（本机库没有卡）');
      final String first = faces.last.cardId;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester, rounds: 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await settle(tester);
      final SrsCardHistory rated = (await tester.runAsync(
        () => host.store.history(first),
      ))!;
      expect(rated.all, hasLength(1), reason: '评分记在主机库');
      expect(host.ops, contains('answerAndStudy'));
      nav.currentState!.pop();
      await settle(tester);

      // 组头菜单：浏览、添加笔记；牌组行菜单（窄屏长按）：牌组设置。页面打开期间的读取都打到主机。
      Future<void> hostMenu(String label) async {
        await tester.tap(
          find.byKey(const ValueKey<String>('srs-paired-menu-host-1')),
        );
        await settle(tester, rounds: 6);
        await tester.tap(find.text(label).last);
      }

      final List<String> browseOps = await opsWhileOpen(
        () => hostMenu(t.srs_browse_title),
      );
      expect(browseOps, contains('browseCommand'), reason: '浏览会话跑在主机库上');
      final List<String> addOps = await opsWhileOpen(
        () => hostMenu(t.srs_note_add),
      );
      expect(addOps, isNotEmpty, reason: '添加笔记页读的是主机库');
      final List<String> settingsOps = await opsWhileOpen(() async {
        await tester.longPress(inRow(deckId, find.text('Default')));
        await settle(tester, rounds: 6);
        expect(
          find.text(t.srs_deck_rename),
          findsNothing,
          reason: '远程牌组菜单不出改结构的项',
        );
        await tester.tap(find.text(t.srs_deck_settings).last);
      });
      expect(settingsOps, isNotEmpty, reason: '牌组设置页读的是主机库');

      expect(local.revision, localRevision, reason: '本机库没被写过');
      expect((await tester.runAsync(() => local.history(first)))!.all, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    /// 能在同一个根容器里关掉 / 重开的首页（模拟离开复习页再回来）。
    Future<ValueNotifier<bool>> pumpReopenableHome(
      WidgetTester tester,
      _CountingConnector connector,
      SrsDbStore local,
    ) async {
      final ValueNotifier<bool> shown = ValueNotifier<bool>(true);
      addTearDown(shown.dispose);
      await _pumpHome(
        tester,
        app: connector.app,
        local: local,
        overrides: <Override>[
          srsRemoteHostConnectorProvider.overrideWithValue(connector),
        ],
        home: ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (BuildContext context, bool on, Widget? _) =>
              on ? const SrsDeckListPage() : const SizedBox.shrink(),
        ),
      );
      return shown;
    }

    Finder pairedHeaderText(String text) => find.descendant(
      of: find.byKey(const ValueKey<String>('srs-paired-header-host-1')),
      matching: find.textContaining(text),
    );

    Future<(_Host, SrsDbStore, _CountingConnector)> openFixture(
      WidgetTester tester,
    ) async {
      final _Host host = (await tester.runAsync(
        () => _openHost(<String>['犬', '猫']),
      ))!;
      addTearDown(() => tester.runAsync(host.db.close));
      final (FushiDatabase localDb, SrsDbStore local) = (await tester.runAsync(
        () => openSrsTestStore(deviceId: 'local'),
      ))!;
      addTearDown(() => tester.runAsync(localDb.close));
      final Directory dir = Directory.systemTemp.createTempSync('srs_rd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      return (host, local, _CountingConnector(SrsTestAppModel(), host, dir));
    }

    testWidgets('再进复习首页：先画上次的主机牌组（更新时间 / 刷新中），后台用同一会话重读，不再探测 / 握手', (
      WidgetTester tester,
    ) async {
      final (_Host host, SrsDbStore local, _CountingConnector connector) =
          await openFixture(tester);
      final ValueNotifier<bool> shown = await pumpReopenableHome(
        tester,
        connector,
        local,
      );
      await settle(tester);
      expect(connector.probes, 1);
      expect(connector.opens, 1);
      expect(pairedHeaderText(t.srs_home_deck_cards(n: 2)), findsOneWidget);
      expect(
        pairedHeaderText(t.srs_home_paired_updated(time: '')),
        findsOneWidget,
      );

      // 离开复习页期间主机上多了一张卡。
      shown.value = false;
      await settle(tester, rounds: 4);
      await tester.runAsync(
        () => host.store.createNote(
          noteTypeId: host.store.lapisNoteTypeId,
          createdAt: 1700000009000,
          fieldsById: <String, String>{
            srsLapisFieldId(kSrsTestProfile, 'Expression'): '鳥',
            srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'def-鳥',
          },
        ),
      );
      final int hellos = host.ops.where((String o) => o == 'hello').length;

      shown.value = true;
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('srs-home-paired')),
        findsOneWidget,
        reason: '分区直接出现，不等探测',
      );
      expect(
        pairedHeaderText(t.srs_home_deck_cards(n: 2)),
        findsOneWidget,
        reason: '先画上次的数字',
      );
      expect(pairedHeaderText(t.srs_home_paired_refreshing), findsOneWidget);

      await settle(tester);
      expect(pairedHeaderText(t.srs_home_deck_cards(n: 3)), findsOneWidget);
      expect(pairedHeaderText(t.srs_home_paired_refreshing), findsNothing);
      expect(connector.probes, 1, reason: '探测结果在本次运行内复用');
      expect(connector.opens, 1, reason: '会话复用，不重新握手');
      expect(
        host.ops.where((String o) => o == 'hello').length,
        hellos,
        reason: '没有新的握手请求',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('主机回包不合契约：组头是可重试的错误态（不停在「0 张」），重试重新握手；失败不清掉上次的牌组', (
      WidgetTester tester,
    ) async {
      final (_Host host, SrsDbStore local, _CountingConnector connector) =
          await openFixture(tester);
      host.malformedDeckSummaries = true;
      final ValueNotifier<bool> shown = await pumpReopenableHome(
        tester,
        connector,
        local,
      );
      await settle(tester);
      final Finder retry = find.byKey(
        const ValueKey<String>('srs-paired-retry-host-1'),
      );
      expect(retry, findsOneWidget, reason: '类型错误也落成可重试的错误态');
      expect(pairedHeaderText(t.srs_home_paired_error_load), findsOneWidget);
      expect(pairedHeaderText(t.srs_home_deck_cards(n: 0)), findsNothing);

      // 主机恢复正常：点重试重新握手，读到牌组。
      host.malformedDeckSummaries = false;
      await tester.tap(retry);
      await settle(tester);
      expect(connector.opens, 2, reason: '出错后会话作废，重试重新握手');
      expect(retry, findsNothing);
      expect(pairedHeaderText(t.srs_home_deck_cards(n: 2)), findsOneWidget);

      // 再进页面时又坏了：错误态，但上次的数字与更新时间还在。
      host.malformedDeckSummaries = true;
      shown.value = false;
      await settle(tester, rounds: 4);
      shown.value = true;
      await settle(tester);
      expect(retry, findsOneWidget);
      expect(pairedHeaderText(t.srs_home_paired_error_load), findsOneWidget);
      expect(
        pairedHeaderText(t.srs_home_deck_cards(n: 2)),
        findsOneWidget,
        reason: '失败不清缓存',
      );
      expect(
        pairedHeaderText(t.srs_home_paired_updated(time: '')),
        findsOneWidget,
      );
      expect(connector.probes, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('没有可用主机：首页不出「已配对设备」分区', (WidgetTester tester) async {
      final (FushiDatabase localDb, SrsDbStore local) = (await tester.runAsync(
        () => openSrsTestStore(deviceId: 'local'),
      ))!;
      addTearDown(() => tester.runAsync(localDb.close));
      // 测试用的 AppModel 没开 app 库：默认连接器找不到主机。
      await _pumpHome(tester, app: SrsTestAppModel(), local: local);
      await settle(tester);
      expect(
        find.byKey(ValueKey<String>('srs-deck-${local.defaultDeckId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('srs-home-paired')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
