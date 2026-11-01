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
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_remote_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
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
  });
}
