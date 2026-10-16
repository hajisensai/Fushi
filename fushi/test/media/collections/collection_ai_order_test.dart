// 合集 AI 排序的装配（真 Drift 内存库 + 假 AI 客户端）：自动路径只在用户没手动排过
// 时落盘且不 bump orderUpdatedAt；没指派 / 没歧义不发请求；用户意图走手动序并切
// manual 偏好；dry-run 不落盘；AI 失败 / 坏回复不改顺序；EPUB 与配对 SRT 同进同出。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/collections/collection_ai_order.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show collectionDetailSortPrefKey, kCollectionDetailManualSortValue;

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

class _Settings implements AiSettingsSource {
  _Settings({required bool assigned})
    : aiFeatureAssignments = assigned
          ? const AiFeatureAssignments().withAssignment(
              AiFeature.collectionOrder,
              'p1',
            )
          : const AiFeatureAssignments();

  @override
  final AiFeatureAssignments aiFeatureAssignments;

  @override
  List<AiProviderConfig> get aiProviders => <AiProviderConfig>[_provider()];

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];
}

/// 假 AI：回 [reply]（或 [status] 非 200 时报错），记请求次数。
class _FakeAi {
  _FakeAi(this.reply, {this.status = 200});

  final String reply;
  final int status;
  int requests = 0;

  AiChatClient create() => AiChatClient(
    client: MockClient((http.Request request) async {
      requests++;
      if (status != 200) return http.Response('{}', status);
      return http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': reply},
            },
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );
}

void main() {
  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
  });

  tearDown(() => db.close());

  Future<void> addVideo(String uid, String file) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(file),
        videoPath: Value<String>('/anime/Show/$file'),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, uid);
  }

  /// 规则序 E01, E02, SP（SP 无集号，规则堆在末尾）。
  Future<void> seedVideos() async {
    await addVideo('v1', '[Grp] Show - 01 [1080p].mkv');
    await addVideo('v2', '[Grp] Show - 02 [1080p].mkv');
    await addVideo('vsp', '[Grp] Show - SP [1080p].mkv');
  }

  Future<List<String>> order() async => <String>[
    for (final MediaCollectionItemRow r in await db.getCollectionItems(
      collectionId,
    ))
      r.entryKey,
  ];

  Future<int> orderUpdatedAt() async =>
      (await db.getMediaCollectionById(collectionId))!.orderUpdatedAt;

  // 规则序里 SP 是下标 2；模型把它放到第 1 集之后。
  const String spAfterFirst = '{"order": [0, 2, 1]}';

  test('自动路径：SP 按 AI 插到第 1 集后，机器序不 bump orderUpdatedAt', () async {
    await seedVideos();
    final _FakeAi ai = _FakeAi(spAfterFirst);
    final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: false,
      clientFactory: ai.create,
    );
    expect(outcome.status, CollectionAiOrderStatus.aiOrdered);
    expect(outcome.persisted, isTrue);
    expect(ai.requests, 1);
    expect(await order(), <String>['v1', 'vsp', 'v2']);
    expect(await orderUpdatedAt(), 0);
    expect(outcome.order.map((CollectionAiOrderEntry e) => e.ambiguous), <bool>[
      false,
      true,
      false,
    ]);
  });

  test('自动路径：用户手动排过（orderUpdatedAt > 0）一个请求都不发', () async {
    await seedVideos();
    await db.reorderCollectionItems(collectionId, <CollectionMemberKey>[
      (mediaType: MediaKind.video.dbValue, entryKey: 'v2'),
    ]);
    final List<String> before = await order();
    final _FakeAi ai = _FakeAi(spAfterFirst);
    final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: false,
      clientFactory: ai.create,
    );
    expect(outcome.status, CollectionAiOrderStatus.skippedManual);
    expect(ai.requests, 0);
    expect(await order(), before);
  });

  test('未指派提供商：不发请求、不动', () async {
    await seedVideos();
    final _FakeAi ai = _FakeAi(spAfterFirst);
    for (final bool userIntent in <bool>[false, true]) {
      final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
        db: db,
        collectionId: collectionId,
        settings: _Settings(assigned: false),
        userIntent: userIntent,
        clientFactory: ai.create,
      );
      expect(outcome.status, CollectionAiOrderStatus.noProvider);
    }
    expect(ai.requests, 0);
    expect(await order(), <String>['v1', 'v2', 'vsp']);
  });

  test('没有歧义：自动路径不发请求；用户意图按规则序落盘', () async {
    await addVideo('v2', 'Show - 02.mkv');
    await addVideo('v1', 'Show - 01.mkv');
    final _FakeAi ai = _FakeAi(spAfterFirst);
    final CollectionAiOrderOutcome auto = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: false,
      clientFactory: ai.create,
    );
    expect(auto.status, CollectionAiOrderStatus.noAmbiguity);
    expect(await order(), <String>['v2', 'v1']);

    final CollectionAiOrderOutcome manual = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: true,
      clientFactory: ai.create,
    );
    expect(manual.status, CollectionAiOrderStatus.ruleOrdered);
    expect(ai.requests, 0);
    expect(await order(), <String>['v1', 'v2']);
  });

  test('用户意图：走手动序（bump orderUpdatedAt）并把详情页排序切成 manual', () async {
    await seedVideos();
    final _FakeAi ai = _FakeAi(spAfterFirst);
    final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: true,
      clientFactory: ai.create,
    );
    expect(outcome.status, CollectionAiOrderStatus.aiOrdered);
    expect(await order(), <String>['v1', 'vsp', 'v2']);
    expect(await orderUpdatedAt(), greaterThan(0));
    expect(
      await db.getPref(collectionDetailSortPrefKey(collectionId)),
      kCollectionDetailManualSortValue,
    );
  });

  test('dry-run：给出建议序但不落盘', () async {
    await seedVideos();
    final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: true,
      dryRun: true,
      clientFactory: _FakeAi(spAfterFirst).create,
    );
    expect(outcome.persisted, isFalse);
    expect(outcome.changed, isTrue);
    expect(
      outcome.order.map((CollectionAiOrderEntry e) => e.entryKey),
      <String>['v1', 'vsp', 'v2'],
    );
    expect(await order(), <String>['v1', 'v2', 'vsp']);
    expect(await orderUpdatedAt(), 0);
  });

  test('AI 请求失败 / 回复没过校验：顺序不变', () async {
    await seedVideos();
    final CollectionAiOrderOutcome failed = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: true,
      clientFactory: _FakeAi('', status: 401).create,
    );
    expect(failed.status, CollectionAiOrderStatus.failed);
    expect(failed.failure, isNotNull);
    final CollectionAiOrderOutcome invalid = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: true,
      clientFactory: _FakeAi('sure!').create,
    );
    expect(invalid.status, CollectionAiOrderStatus.invalidReply);
    expect(await order(), <String>['v1', 'v2', 'vsp']);
    expect(await orderUpdatedAt(), 0);
  });

  test('书：EPUB 与配对 SRT 是同一卷，汉字卷号交 AI 定位后两行相邻', () async {
    Future<String> addEpub(String title) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: title,
          title: title,
          epubPath: '/b/$title',
          extractDir: '/b/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
        ),
      );
      final String uid = (await db.resolveEpubBookUid(title))!;
      await db.addToCollection(collectionId, MediaKind.epub, uid);
      return uid;
    }

    final String v1 = await addEpub('物語 1');
    final String v3 = await addEpub('物語 第三巻');
    final String v2 = await addEpub('物語 2');
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt_v1',
        title: '物語 1（有声书）',
        srtPath: '/s/1.srt',
        importedAt: 1000,
        bookKey: const Value<String>('物語 1'),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.srt, 'srt_v1');

    // 规则序（单元）：「第三巻」认不出卷号、按第 0 卷排在最前 → 0=第三巻
    // 1=物語 1(+srt) 2=物語 2。模型给出读序 1, 2, 第三巻。
    final _FakeAi ai = _FakeAi('{"order": [1, 2, 0]}');
    final CollectionAiOrderOutcome outcome = await runCollectionAiOrder(
      db: db,
      collectionId: collectionId,
      settings: _Settings(assigned: true),
      userIntent: true,
      clientFactory: ai.create,
    );
    expect(outcome.status, CollectionAiOrderStatus.aiOrdered);
    expect(await order(), <String>[v1, 'srt_v1', v2, v3]);
  });
}
