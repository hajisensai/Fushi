// AI 整理库引擎（spec docs/specs/2026-10-20-ai-library-organize-design.md §7 / §12）：
// 真 Drift 内存库 + 假 AI。直接改库、可撤销；撤销新建 = 拒绝，之后不再建；用户合集
// 只能往里加；置信度门槛按触发方式；没指派不发请求；自动整理有每日额度。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

class _Settings implements AiSettingsSource {
  _Settings({bool assigned = true})
    : aiFeatureAssignments = assigned
          ? const AiFeatureAssignments().withAssignment(
              AiFeature.libraryOrganize,
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

/// 假 AI：按请求内容回复（[reply] 拿到用户提示词）；记下请求。
class _FakeAi {
  _FakeAi(this.reply);

  final String Function(String userPrompt) reply;
  final List<String> prompts = <String>[];

  AiChatClient create() => AiChatClient(
    client: MockClient((http.Request request) async {
      final Map<String, Object?> body =
          jsonDecode(request.body) as Map<String, Object?>;
      final List<Object?> messages = body['messages']! as List<Object?>;
      final String user =
          (messages.last! as Map<String, Object?>)['content']! as String;
      prompts.add(user);
      return http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': reply(user)},
            },
          ],
          'usage': <String, Object?>{
            'prompt_tokens': 100,
            'completion_tokens': 20,
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );
}

/// 用户提示词里某标题的条目下标。
int _indexOf(String prompt, String title) {
  for (final String line in const LineSplitter().convert(prompt)) {
    if (!line.startsWith('{"i":')) continue;
    final Map<String, Object?> j = jsonDecode(line) as Map<String, Object?>;
    if (j['title'] == title) return j['i']! as int;
  }
  throw StateError('no item $title in prompt');
}

/// 用户提示词里某合集名的编号。
String _collectionIdOf(String prompt, String name) {
  for (final String line in const LineSplitter().convert(prompt)) {
    if (!line.startsWith('{"id":')) continue;
    final Map<String, Object?> j = jsonDecode(line) as Map<String, Object?>;
    if (j['name'] == name) return j['id']! as String;
  }
  throw StateError('no collection $name in prompt');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseAiLibraryOrganizeReply', () {
    test('剔除越界 / 重复下标与不认识的合集；围栏与散文照样能读', () {
      final AiOrganizeReply reply = parseAiLibraryOrganizeReply(
        'sure!\n```json\n${jsonEncode(<String, Object?>{
          'groups': <Object?>[
            <String, Object?>{
              'members': <Object?>[0, 1, 1, 9, '2'],
              'name': 'S',
              'confidence': 'high',
            },
            <String, Object?>{
              'members': <Object?>[3],
              'into': 'C7',
              'name': '',
              'confidence': 'high',
            },
            <String, Object?>{
              'members': <Object?>[3],
              'name': 'only one',
              'confidence': 'high',
            },
          ],
          'merges': <Object?>[
            <String, Object?>{
              'collections': <Object?>['C0', 'C0', 'C1'],
              'confidence': 'medium',
            },
          ],
          'evictions': <Object?>[
            <String, Object?>{
              'collection': 'C1',
              'members': <Object?>[3],
              'confidence': 'bogus',
            },
          ],
        })}\n```',
        itemCount: 4,
        collectionIds: <String>{'C0', 'C1'},
      )!;
      expect(reply.groups, hasLength(1));
      expect(reply.groups.single.members, <int>[0, 1, 2]);
      expect(reply.merges.single.collections, <String>['C0', 'C1']);
      expect(reply.evictions, isEmpty);
    });

    test('不是 JSON 对象返回 null', () {
      expect(
        parseAiLibraryOrganizeReply(
          'I cannot help',
          itemCount: 1,
          collectionIds: const <String>{},
        ),
        isNull,
      );
    });
  });

  group('planFromAiReply（视频作品 / 系列两层）', () {
    LibraryOrganizeFacts videoFacts(List<OrganizeEntry> entries) =>
        LibraryOrganizeFacts(
          domain: CollectionShelfDomain.video,
          entries: entries,
          collections: const <OrganizeCollectionFact>[],
          rejectedKeys: const <String>{},
          rejectedNames: const <String, String>{},
          takenNames: const <String, Set<String>>{},
        );
    OrganizeEntry video(String uid, String? work) => OrganizeEntry(
      mediaType: 'video',
      entryKey: uid,
      tombstoneKey: 'video\u0000$uid',
      externalWorkKey: work,
      item: AiOrganizeItem(title: uid),
    );

    test('「同一部作品」成员刮到不同作品 → 改成系列标签，不建合集', () {
      final List<OrganizeEntry> entries = <OrganizeEntry>[
        video('s1e1', 'anilist:1'),
        video('s2e1', 'anilist:2'),
      ];
      final List<OrganizeAction> plan = planFromAiReply(
        facts: videoFacts(entries),
        chunk: OrganizeChunk(
          entries: entries,
          collections: const <OrganizeCollectionFact>[],
        ),
        reply: const AiOrganizeReply(
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: <int>[0, 1],
              name: '物語',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
        trigger: OrganizeTrigger.manual,
        tagPrefix: '系列:',
      );
      expect(plan.single.kind, OrganizeActionKind.tag);
      expect(plan.single.name, '系列:物語');
    });

    test('同一份回复里「合并 C1、C2」+「并入 C2」→ 改并进胜方', () {
      OrganizeCollectionFact col(int id, String name) => OrganizeCollectionFact(
        id: id,
        name: name,
        collectionType: 'playlist',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-$name',
        organizeAliases: const <String>{},
        memberKeys: const <String>{},
        sampleTitles: const <String>[],
      );
      final List<OrganizeCollectionFact> cols = <OrganizeCollectionFact>[
        col(1, 'A'),
        col(2, 'B'),
      ];
      final List<OrganizeEntry> entries = <OrganizeEntry>[video('x', null)];
      final List<OrganizeAction> plan = planFromAiReply(
        facts: LibraryOrganizeFacts(
          domain: CollectionShelfDomain.video,
          entries: entries,
          collections: cols,
          rejectedKeys: const <String>{},
          rejectedNames: const <String, String>{},
          takenNames: const <String, Set<String>>{},
        ),
        chunk: OrganizeChunk(entries: entries, collections: cols),
        reply: const AiOrganizeReply(
          merges: <AiOrganizeMergeProposal>[
            AiOrganizeMergeProposal(
              collections: <String>['C0', 'C1'],
              confidence: AiOrganizeConfidence.high,
            ),
          ],
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: <int>[0],
              into: 'C1',
              name: '',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
        trigger: OrganizeTrigger.manual,
        tagPrefix: '',
      );
      final OrganizeAction merge = plan.singleWhere(
        (OrganizeAction a) => a.kind == OrganizeActionKind.merge,
      );
      final OrganizeAction add = plan.singleWhere(
        (OrganizeAction a) => a.kind == OrganizeActionKind.add,
      );
      expect(add.targetCollectionId, merge.targetCollectionId);
    });

    test('同一外部作品 → 合集键取外部 id；置信度 medium 自动时不落', () {
      final List<OrganizeEntry> entries = <OrganizeEntry>[
        video('e1', 'anilist:9'),
        video('e2', 'anilist:9'),
      ];
      AiOrganizeReply reply(AiOrganizeConfidence c) => AiOrganizeReply(
        groups: <AiOrganizeGroupProposal>[
          AiOrganizeGroupProposal(
            members: const <int>[0, 1],
            name: 'Frieren',
            originalTitle: '葬送のフリーレン',
            level: AiOrganizeLevel.work,
            confidence: c,
          ),
        ],
      );
      final OrganizeChunk chunk = OrganizeChunk(
        entries: entries,
        collections: const <OrganizeCollectionFact>[],
      );
      final List<OrganizeAction> manual = planFromAiReply(
        facts: videoFacts(entries),
        chunk: chunk,
        reply: reply(AiOrganizeConfidence.medium),
        trigger: OrganizeTrigger.manual,
        tagPrefix: '',
      );
      expect(manual.single.kind, OrganizeActionKind.create);
      expect(manual.single.organizeKey, 'anilist:9');
      expect(
        planFromAiReply(
          facts: videoFacts(entries),
          chunk: chunk,
          reply: reply(AiOrganizeConfidence.medium),
          trigger: OrganizeTrigger.auto,
          tagPrefix: '',
        ),
        isEmpty,
      );
    });
  });

  group('LibraryOrganizeService（真库 + 假 AI）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<String> book(String title, {String format = 'epub'}) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: title,
          title: title,
          epubPath: '/m/$title',
          extractDir: '/m/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          format: Value<String>(format),
        ),
      );
      return (await db.resolveEpubBookUid(title))!;
    }

    LibraryOrganizeService service(_FakeAi ai, {bool assigned = true}) =>
        LibraryOrganizeService(
          db: db,
          settings: _Settings(assigned: assigned),
          nameLanguage: 'ja',
          videoTagPrefix: '系列:',
          clientFactory: ai.create,
        );

    const List<String> haruhi = <String>['涼宮ハルヒの憂鬱', '涼宮ハルヒの溜息', '涼宮ハルヒの退屈'];

    String groupHaruhi(String prompt, {String confidence = 'high'}) =>
        jsonEncode(<String, Object?>{
          'groups': <Object?>[
            <String, Object?>{
              'members': <int>[
                for (final String t in haruhi) _indexOf(prompt, t),
              ],
              'name': '涼宮ハルヒ',
              'originalTitle': '涼宮ハルヒシリーズ',
              'level': 'work',
              'confidence': confidence,
            },
          ],
        });

    test('新建 AI 合集：来源 ai、带键、写整理记录；撤销 = 拒绝，再跑不再建', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      final _FakeAi ai = _FakeAi(groupHaruhi);
      final LibraryOrganizeResult first = await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(first.status, LibraryOrganizeStatus.done);
      expect(first.requests, 1);
      final MediaCollectionRow c = (await db.getMediaCollectionByNaturalKey(
        '涼宮ハルヒ',
        'playlist',
      ))!;
      expect(c.origin, 'ai');
      expect(c.organizeKey, titleOrganizeKey('books', '涼宮ハルヒシリーズ'));
      expect(await db.getCollectionItems(c.id), hasLength(3));
      final List<LibraryOrganizeChangeRow> changes = await db
          .select(db.libraryOrganizeChanges)
          .get();
      expect(changes.single.kind, 'create');
      final LibraryOrganizeRunRow run =
          (await db.select(db.libraryOrganizeRuns).get()).single;
      expect(run.status, 'done');
      expect(run.inputTokens, 100);

      expect(await undoLibraryOrganizeChanges(db, <int>[changes.single.id]), 1);
      expect(await db.getMediaCollectionById(c.id), isNull);
      expect(await db.getRejectedOrganizeKeys(), <String>{c.organizeKey!});

      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(
        await db.getMediaCollectionByNaturalKey('涼宮ハルヒ', 'playlist'),
        isNull,
        reason: '被拒绝的分组不复活',
      );
      // 拒绝表随请求发给 AI（模型也被告知别再提）。
      expect(ai.prompts.last, contains('rejected: [{"key":"${c.organizeKey}"'));
    });

    test('并入用户合集：只加成员，合集仍归用户', () async {
      final String a = await book('とある魔術の禁書目録');
      await book('魔法禁书目录 22');
      final int user = await db.createMediaCollection('禁書');
      await db.addToCollection(user, MediaKind.epub, a);
      final _FakeAi ai = _FakeAi(
        (String prompt) => jsonEncode(<String, Object?>{
          'groups': <Object?>[
            <String, Object?>{
              'members': <int>[_indexOf(prompt, '魔法禁书目录 22')],
              'into': _collectionIdOf(prompt, '禁書'),
              'name': '',
              'confidence': 'high',
            },
          ],
        }),
      );
      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(await db.getCollectionItems(user), hasLength(2));
      expect((await db.getMediaCollectionById(user))!.origin, 'user');
    });

    test('自动整理只落 high；medium 留给手动', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      final _FakeAi ai = _FakeAi(
        (String p) => groupHaruhi(p, confidence: 'medium'),
      );
      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.auto);
      expect(await db.getAllMediaCollections(), isEmpty);
      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(await db.getAllMediaCollections(), hasLength(1));
    });

    test('只整理指定条目时，整理器合集里没被点名的成员一条都不发', () async {
      final int c = await db.createMediaCollection(
        'Old',
        collectionType: 'playlist',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-old',
      );
      for (int i = 0; i < 5; i++) {
        await db.addToCollection(
          c,
          MediaKind.epub,
          await book('old-$i'),
          userIntent: false,
        );
      }
      final String fresh = await book('fresh');
      final _FakeAi ai = _FakeAi((_) => '{"groups": []}');
      await service(ai).run(
        CollectionShelfDomain.books,
        trigger: OrganizeTrigger.auto,
        onlyEntryKeys: <String>{'epub\u0000$fresh'},
      );
      expect(ai.prompts.single, contains('"title":"fresh"'));
      expect(ai.prompts.single, isNot(contains('"title":"old-0"')));
      // 合集本身照常带上（名字 + 样本），AI 能把新条目并进去。
      expect(ai.prompts.single, contains('"name":"Old"'));
    });

    test('自动整理被额度截断 = partial，不推进水位', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      await db
          .into(db.libraryOrganizeRuns)
          .insert(
            LibraryOrganizeRunsCompanion.insert(
              domain: 'books',
              trigger: 'auto',
              startedAt: DateTime.now().millisecondsSinceEpoch,
              status: 'done',
              requestCount: const Value<int>(kLibraryOrganizeDailyAutoRequests),
            ),
          );
      final LibraryOrganizeService s = service(_FakeAi(groupHaruhi));
      final int? before = await s.lastCompletedAutoRunStartedAt(
        CollectionShelfDomain.books,
      );
      final LibraryOrganizeResult r = await s.run(
        CollectionShelfDomain.books,
        trigger: OrganizeTrigger.auto,
      );
      expect(r.status, LibraryOrganizeStatus.overBudget);
      final LibraryOrganizeRunRow row = (await (db.select(
        db.libraryOrganizeRuns,
      )..where((t) => t.id.equals(r.runId))).get()).single;
      expect(row.status, 'partial');
      expect(
        await s.lastCompletedAutoRunStartedAt(CollectionShelfDomain.books),
        before,
        reason: '截断的那次不算跑完',
      );
    });

    test('没指派提供商：不发请求、不改库', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      final _FakeAi ai = _FakeAi(groupHaruhi);
      final LibraryOrganizeResult r = await service(
        ai,
        assigned: false,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(r.status, LibraryOrganizeStatus.noProvider);
      expect(ai.prompts, isEmpty);
      expect(await db.getAllMediaCollections(), isEmpty);
    });

    test('自动整理每日额度用完：不再发请求', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      await db
          .into(db.libraryOrganizeRuns)
          .insert(
            LibraryOrganizeRunsCompanion.insert(
              domain: 'books',
              trigger: 'auto',
              startedAt: DateTime.now().millisecondsSinceEpoch,
              status: 'done',
              requestCount: const Value<int>(kLibraryOrganizeDailyAutoRequests),
            ),
          );
      final _FakeAi ai = _FakeAi(groupHaruhi);
      final LibraryOrganizeResult r = await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.auto);
      expect(r.status, LibraryOrganizeStatus.overBudget);
      expect(ai.prompts, isEmpty);
    });

    test('漫画与书分域：书的整理看不到漫画', () async {
      await book('ワンピース 1', format: 'manga');
      final _FakeAi ai = _FakeAi((_) => '{"groups": []}');
      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(ai.prompts, isEmpty, reason: '书架里没有条目，不发请求');
      await service(
        ai,
      ).run(CollectionShelfDomain.manga, trigger: OrganizeTrigger.manual);
      expect(ai.prompts.single, contains('ワンピース 1'));
    });

    test('合并两个 AI 合集后撤销：败方按快照重建为用户合集，收敛不再合并', () async {
      final String a = await book('A1');
      final String b = await book('B1');
      final int ca = await db.createMediaCollection(
        'A',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-a',
      );
      final int cb = await db.createMediaCollection(
        'B',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-b',
      );
      await db.addToCollection(ca, MediaKind.epub, a, userIntent: false);
      await db.addToCollection(cb, MediaKind.epub, b, userIntent: false);
      final _FakeAi ai = _FakeAi(
        (String prompt) => jsonEncode(<String, Object?>{
          'merges': <Object?>[
            <String, Object?>{
              'collections': <String>[
                _collectionIdOf(prompt, 'A'),
                _collectionIdOf(prompt, 'B'),
              ],
              'confidence': 'high',
            },
          ],
        }),
      );
      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      expect(await db.getMediaCollectionById(cb), isNull);
      expect(await db.getCollectionItems(ca), hasLength(2));
      final LibraryOrganizeChangeRow merge =
          (await db.select(db.libraryOrganizeChanges).get()).singleWhere(
            (LibraryOrganizeChangeRow r) => r.kind == 'merge',
          );
      await undoLibraryOrganizeChanges(db, <int>[merge.id]);
      final MediaCollectionRow restored =
          (await db.getMediaCollectionByNaturalKey('B', 'playlist') ??
          await db.getMediaCollectionByNaturalKey('B', 'collection'))!;
      expect(restored.origin, 'user');
      expect(
        (await db.getCollectionItems(
          restored.id,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        <String>[b],
      );
      expect(
        (await db.getCollectionItems(
          ca,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        <String>[a],
      );
      expect((await db.getMediaCollectionById(ca))!.origin, 'user');
      expect(
        decodeOrganizeAliases(
          (await db.getMediaCollectionById(ca))!.organizeAliases,
        ),
        isNot(contains('k-b')),
        reason: '撤销合并要把败方的键还回去',
      );
    });

    test('新合集撞上别的分组删过的同名：换成确定性的名字', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      final int other = await db.createMediaCollection(
        '涼宮ハルヒ',
        collectionType: 'playlist',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-other',
      );
      final String filler = await book('filler');
      await db.addToCollection(
        other,
        MediaKind.epub,
        filler,
        userIntent: false,
      );
      await db.deleteMediaCollection(other);
      final _FakeAi ai = _FakeAi(groupHaruhi);
      await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      final String key = titleOrganizeKey('books', '涼宮ハルヒシリーズ')!;
      expect(
        await db.getMediaCollectionByNaturalKey(
          disambiguatedOrganizeName('涼宮ハルヒ', key),
          'playlist',
        ),
        isNotNull,
      );
    });

    test('同一份回复两组撞名：各建各的合集，不被按自然键并成一个；撤销两处都删', () async {
      for (final String t in haruhi) {
        await book(t);
      }
      await book('長門有希の消失 1');
      await book('長門有希の消失 2');
      final _FakeAi ai = _FakeAi(
        (String prompt) => jsonEncode(<String, Object?>{
          'groups': <Object?>[
            <String, Object?>{
              'members': <int>[
                for (final String t in haruhi) _indexOf(prompt, t),
              ],
              'name': 'SOS団',
              'originalTitle': '涼宮ハルヒシリーズ',
              'level': 'work',
              'confidence': 'high',
            },
            <String, Object?>{
              'members': <int>[
                _indexOf(prompt, '長門有希の消失 1'),
                _indexOf(prompt, '長門有希の消失 2'),
              ],
              'name': 'SOS団',
              'originalTitle': '長門有希ちゃんの消失',
              'level': 'work',
              'confidence': 'high',
            },
          ],
        }),
      );
      final LibraryOrganizeResult r = await service(
        ai,
      ).run(CollectionShelfDomain.books, trigger: OrganizeTrigger.manual);
      final String haruhiKey = titleOrganizeKey('books', '涼宮ハルヒシリーズ')!;
      final String nagatoKey = titleOrganizeKey('books', '長門有希ちゃんの消失')!;
      expect(haruhiKey, isNot(nagatoKey));
      final MediaCollectionRow first = (await db.getMediaCollectionByNaturalKey(
        'SOS団',
        'playlist',
      ))!;
      final MediaCollectionRow second = (await db
          .getMediaCollectionByNaturalKey(
            disambiguatedOrganizeName('SOS団', nagatoKey),
            'playlist',
          ))!;
      expect(first.organizeKey, haruhiKey);
      expect(second.organizeKey, nagatoKey);
      expect(await db.getCollectionItems(first.id), hasLength(3));
      expect(await db.getCollectionItems(second.id), hasLength(2));
      expect(
        (await db.select(db.libraryOrganizeChanges).get()).map(
          (LibraryOrganizeChangeRow c) => c.kind,
        ),
        <String>['create', 'create'],
      );

      expect(await undoLibraryOrganizeRun(db, r.runId), 2);
      expect(await db.getAllMediaCollections(), isEmpty);
    });

    test('新建落到同名已有合集：按并入记录，撤销只移出这次加的、不删原合集', () async {
      final String a = await book('A1');
      final String b = await book('B1');
      final int user = await db.createMediaCollection(
        'Shared',
        collectionType: 'playlist',
      );
      await db.addToCollection(user, MediaKind.epub, a);
      await applyOrganizeActions(
        db,
        runId: 1,
        actions: <OrganizeAction>[
          OrganizeAction(
            kind: OrganizeActionKind.create,
            source: 'ai',
            confidence: AiOrganizeConfidence.high,
            name: 'Shared',
            organizeKey: 'k-new',
            entries: <OrganizeEntry>[
              OrganizeEntry(
                mediaType: MediaKind.epub.dbValue,
                entryKey: b,
                tombstoneKey: 'epub\u0000$b',
                item: const AiOrganizeItem(title: 'B1'),
              ),
            ],
          ),
        ],
      );
      final LibraryOrganizeChangeRow change =
          (await db.select(db.libraryOrganizeChanges).get()).single;
      expect(change.kind, 'add', reason: '复用了已有行就不是新建');
      expect(jsonDecode(change.payloadJson), isNot(contains('created')));
      expect((await db.getMediaCollectionById(user))!.origin, 'user');

      expect(await undoLibraryOrganizeChanges(db, <int>[change.id]), 1);
      expect(await db.getMediaCollectionById(user), isNotNull);
      expect(
        (await db.getCollectionItems(
          user,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        <String>[a],
      );
    });

    test('旧的「新建」记录落在同名已有整理器合集上：撤销不删它', () async {
      final String a = await book('A1');
      final String b = await book('B1');
      final int existing = await db.createMediaCollection(
        'Old',
        collectionType: 'playlist',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-old',
      );
      await db.addToCollection(existing, MediaKind.epub, a, userIntent: false);
      await db.addToCollection(existing, MediaKind.epub, b, userIntent: false);
      // 修复前的落盘：复用了已有行，却记成「新建」（没有 created 标记）。
      final int changeId = await db
          .into(db.libraryOrganizeChanges)
          .insert(
            LibraryOrganizeChangesCompanion.insert(
              runId: 1,
              kind: 'create',
              collectionName: 'Old',
              collectionType: 'playlist',
              organizeKey: const Value<String?>('k-old'),
              source: 'ai',
              confidence: 'high',
              payloadJson: jsonEncode(<String, Object?>{
                'members': <Map<String, String>>[
                  <String, String>{'t': 'epub', 'k': b},
                ],
              }),
            ),
          );
      expect(await undoLibraryOrganizeChanges(db, <int>[changeId]), 1);
      expect(await db.getMediaCollectionById(existing), isNotNull);
      expect(
        (await db.getCollectionItems(
          existing,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        <String>[a],
      );
    });

    test('新建落到同名的空合集且成员全被移出过：不删那个原本就在的合集', () async {
      final String b = await book('B1');
      final int empty = await db.createMediaCollection(
        'Empty',
        collectionType: 'playlist',
      );
      await db.upsertCollectionMemberTombstone(
        collectionName: 'Empty',
        collectionType: 'playlist',
        mediaType: 'epub',
        entryKey: 'tomb-b',
        deletedAt: 1,
      );
      await applyOrganizeActions(
        db,
        runId: 1,
        actions: <OrganizeAction>[
          OrganizeAction(
            kind: OrganizeActionKind.create,
            source: 'ai',
            confidence: AiOrganizeConfidence.high,
            name: 'Empty',
            organizeKey: 'k-new',
            entries: <OrganizeEntry>[
              OrganizeEntry(
                mediaType: MediaKind.epub.dbValue,
                entryKey: b,
                tombstoneKey: 'epub\u0000tomb-b',
                item: const AiOrganizeItem(title: 'B1'),
              ),
            ],
          ),
        ],
      );
      expect(await db.getMediaCollectionById(empty), isNotNull);
      expect(await db.select(db.libraryOrganizeChanges).get(), isEmpty);
    });
  });
}
