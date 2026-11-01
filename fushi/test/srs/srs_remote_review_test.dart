// 复习远程刷卡（docs/specs/2026-11-01-srs-remote-review-design.md）的客户端端到端：
// SrsRemoteReviewClient → MockClient → 真实的 `/api/srs/review/*` 路由 → SrsRemoteReviewService → 内存库上的 SrsDbStore。
//
// - 回包丢了（host 已记下）客户端用同一请求 id 重发：只记一条日志；
// - 出卡后卡在 host 上被复习过：作答回 stale；
// - 媒体按名字拉进缓存，同名只拉一次，非法名字不发请求；
// - 页面：问题面 → 显示答案 → 评分 → 下一张；撤销带回上一张。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_remote_review_page.dart';
import 'package:fushi/src/srs/srs_card_media.dart';

import 'package:fushi/src/srs/srs_remote_review_client.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_review.dart';
import 'package:fushi_engine/srs/srs_remote_review_routes.dart';
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

/// 一台「电脑」：内存库上的复习 + 远程刷卡服务；[client] 经 MockClient 打到真实路由。
class _Host {
  _Host(this.db, this.store, this.service);

  final FushiDatabase db;
  final SrsDbStore store;
  final SrsRemoteReviewService service;

  /// 作答请求「host 处理完、回包丢了」的次数（> 0 时下一次作答回包丢掉）。
  int dropAnswerResponses = 0;
  final List<String> paths = <String>[];
  final Map<String, Uint8List> media = <String, Uint8List>{};

  late final SyncRepository repository = SyncRepository(db);

  SrsRemoteReviewClient client() => SrsRemoteReviewClient(
    repository: repository,
    peer: _peer,
    httpClient: MockClient((http.Request r) async {
      final String path = r.url.path;
      paths.add(path);
      if (!path.startsWith(kSrsRemoteReviewPathPrefix)) {
        return http.Response('', 404);
      }
      final shelf.Response res = await handleSrsRemoteReviewRequest(
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
      if (path.endsWith('/answer') && dropAnswerResponses > 0) {
        dropAnswerResponses--;
        throw const SocketException('response lost');
      }
      return http.Response.bytes(bytes, res.statusCode, headers: res.headers);
    }),
  );
}

Future<_Host> _openHost(List<String> expressions) async {
  final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
  for (final String e in expressions) {
    await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): e,
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'def-$e',
      },
    );
  }
  late final _Host host;
  host = _Host(
    db,
    store,
    SrsRemoteReviewService(
      readStore: () async => store,
      readMedia: (String name) async => host.media[name],
    ),
  );
  await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[_peer]);
  return host;
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

  group('客户端 ↔ host', () {
    late _Host host;
    setUp(() async {
      host = await _openHost(<String>['犬', '猫', '鳥']);
    });
    tearDown(() => host.db.close());

    test('回包丢了用同一请求 id 重发：只记一条日志', () async {
      final SrsRemoteReviewClient client = host.client();
      final ({String profile, List<SrsRemoteDeck> decks}) decks = await client
          .decks();
      final String deck = host.store.defaultDeckId;
      expect(decks.decks.map((SrsRemoteDeck d) => d.id), contains(deck));
      final SrsRemoteStudy study = await client.next(
        profile: decks.profile,
        deck: deck,
      );
      final SrsRemoteCard card = study.cards.first;
      expect(card.intervalOf(3), isNotNull);

      host.dropAnswerResponses = 1;
      final String request = client.requestId();
      await expectLater(
        client.answer(
          profile: decks.profile,
          request: request,
          deck: deck,
          card: card,
          rating: 3,
          durationMs: 1200,
        ),
        throwsA(
          isA<InterconnectHostError>().having(
            (InterconnectHostError e) => e.message,
            'message',
            InterconnectHostError.unreachableCode,
          ),
        ),
      );
      final ({String logId, SrsRemoteStudy study}) retried = await client
          .answer(
            profile: decks.profile,
            request: request,
            deck: deck,
            card: card,
            rating: 3,
            durationMs: 1200,
          );
      expect((await host.store.history(card.id)).all, hasLength(1));
      expect((await host.store.history(card.id)).all.single.id, retried.logId);
      expect(
        retried.study.cards.map((SrsRemoteCard c) => c.id),
        isNot(contains(card.id)),
      );
    });

    test('出卡后卡在 host 上被复习过：作答回 stale', () async {
      final SrsRemoteReviewClient client = host.client();
      final String deck = host.store.defaultDeckId;
      final SrsRemoteStudy study = await client.next(
        profile: host.store.profileUid,
        deck: deck,
      );
      final SrsRemoteCard card = study.cards.first;
      await host.store.answer(card.id, 4);
      await expectLater(
        client.answer(
          profile: host.store.profileUid,
          request: client.requestId(),
          deck: deck,
          card: card,
          rating: 1,
          durationMs: 1000,
        ),
        throwsA(
          isA<InterconnectHostError>().having(
            (InterconnectHostError e) => e.message,
            'message',
            SrsRemoteReviewError.stale,
          ),
        ),
      );
      expect((await host.store.history(card.id)).all, hasLength(1));
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
      final Iterable<String> mediaHits = host.paths.where(
        (String p) => p.contains('/media/'),
      );
      expect(mediaHits.where((String p) => p.endsWith('/a.png')), hasLength(1));
      expect(mediaHits.where((String p) => p.contains('evil')), isEmpty);
    });
  });

  group('页面', () {
    Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
      for (int i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('显示答案 → 评分 → 下一张；撤销带回上一张', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Host host = (await tester.runAsync(
        () => _openHost(<String>['犬', '猫']),
      ))!;
      addTearDown(() => tester.runAsync(host.db.close));
      final Directory dir = Directory.systemTemp.createTempSync('srs_rp_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final AppModel app = AppModel(testPlatformServices())
        ..shortcutRegistry.loadDefaults(TargetPlatform.windows);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => app),
            srsCardFaceBuilderProvider.overrideWithValue(
              (BuildContext context, SrsCardFace face) =>
                  SrsPlainCardFace(face: face),
            ),
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
              home: SrsRemoteReviewPage(
                client: host.client(),
                hostId: 'host-1',
                profile: host.store.profileUid,
                deckId: host.store.defaultDeckId,
                deckName: 'Default',
                mediaRoot: dir,
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final Finder showAnswer = find.byKey(
        const ValueKey<String>('srs-remote-show-answer'),
      );
      expect(showAnswer, findsOneWidget);
      String face() => tester
          .widget<SrsPlainCardFace>(find.byType(SrsPlainCardFace))
          .face
          .bodyHtml;
      final String firstQuestion = face();
      expect(firstQuestion, anyOf(contains('犬'), contains('猫')));

      await tester.tap(showAnswer);
      await settle(tester, rounds: 4);
      final Finder good = find.byKey(
        const ValueKey<String>('srs-remote-rate-3'),
      );
      expect(good, findsOneWidget);

      await tester.tap(good);
      await settle(tester);
      expect(showAnswer, findsOneWidget);
      final String secondQuestion = face();
      expect(secondQuestion, isNot(firstQuestion));
      expect(
        host.paths.where((String p) => p.endsWith('/answer')),
        hasLength(1),
      );

      final Finder undo = find.byKey(const ValueKey<String>('srs_remote_undo'));
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await settle(tester);
      expect(face(), firstQuestion);
      expect(host.paths.where((String p) => p.endsWith('/undo')), hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
