// 「我库里的例句」app 侧编排（LibraryCorpusService）：真 fushi_corpus 原生库 + 真内存库，
// 只把词典词元换成确定性的假实现（空格分词、小写 = 词典形），这样调度 / 增量 / 重新归一
// 能在没有词典原生库的环境里跑。原生 fushi_corpus / fushi_compute 是硬依赖：找不到库直接红。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/corpus/library_corpus_service.dart';
import 'package:fushi/src/corpus/library_sentences_bridge.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart';

/// 假词元：按空白切词，词典形 = 小写（模拟「Ran → run」一类归一就够了：这里测的是编排）。
Uint8List fakeTerms(List<String> sentences) {
  final BytesBuilder b = BytesBuilder();
  void u32(int v) {
    final ByteData d = ByteData(4)..setUint32(0, v, Endian.little);
    b.add(d.buffer.asUint8List());
  }

  for (final String s in sentences) {
    final List<RegExpMatch> words = RegExp(r'[^\s]+').allMatches(s).toList();
    u32(words.length);
    for (final RegExpMatch m in words) {
      final List<int> lemma = utf8.encode(m.group(0)!.toLowerCase());
      u32(m.start);
      u32(m.end - m.start);
      u32(lemma.length);
      b.add(lemma);
    }
  }
  return b.takeBytes();
}

class FakeNormalizer implements CorpusNormalizer {
  @override
  String? signature = 'dict-v1';

  int backgroundRuns = 0;

  @override
  Future<T?> runInBackground<T>(T Function(CorpusTermsFn terms) job) {
    backgroundRuns++;
    return Isolate.run(() => job(fakeTerms));
  }
}

/// 语料库里的游戏文档：(key, normalizer)。经服务自己的后台 isolate 读（与它共享同一句柄）。
Future<List<(String, String)>> _gameDocs(LibraryCorpusService service) async {
  final List<CorpusDocInfo> docs = await service.debugDocs(
    CorpusSourceKind.game,
  );
  return <(String, String)>[
    for (final CorpusDocInfo d in docs) (d.key, d.normalizer),
  ];
}

void main() {
  late Directory dir;
  late FushiDatabase db;
  late FakeNormalizer normalizer;
  late LibraryCorpusService service;
  late bool enabled;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('fushi_corpus_service');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    normalizer = FakeNormalizer();
    enabled = true;
    service = LibraryCorpusService(
      normalizer: normalizer,
      startDelay: Duration.zero,
      debounce: const Duration(milliseconds: 1),
      gameFlushDelay: const Duration(hours: 1),
    );
    service.start(database: db, directory: dir.path, isEnabled: () => enabled);
    // 让 startDelay 的计时器跑完首轮对账。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.idle;
  });

  tearDown(() async {
    await service.stop();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> addGame(String id) => db.upsertGalgame(
    GalgamesCompanion.insert(
      id: id,
      name: 'Some Game',
      exePath: '/g/$id.exe',
      workdir: '/g',
      addedAt: 0,
    ),
  );

  /// 等表变化的去抖对账与它排出的喂入任务都跑完。
  Future<void> settle() async {
    for (int i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await service.idle;
    }
  }

  test('游戏台词：逐段重绘按行 id 覆盖、外部通道前缀续写覆盖，落库后可查', () async {
    await addGame('g1');
    service
      ..feedGameLine(
        gameId: 'g1',
        lineKey: 'line-1',
        text: 'The dog',
        atMs: 1000,
      )
      ..feedGameLine(
        gameId: 'g1',
        lineKey: 'line-1',
        text: 'The dog RAN home',
        atMs: 1100,
      )
      ..feedGameLine(gameId: 'g1', lineKey: null, text: 'A cat', atMs: 2000)
      ..feedGameLine(
        gameId: 'g1',
        lineKey: null,
        text: 'A cat ran too',
        atMs: 2100,
      );
    await service.flushGameLines();
    await settle();

    // 台词落进 galgame_text_lines（唯一持久副本，随备份走）：折叠后只有两行。
    expect(
      (await db.select(db.galgameTextLines).get())
          .map((GalgameTextLineRow r) => r.lineText)
          .toList(),
      <String>['The dog RAN home', 'A cat ran too'],
    );
    final CorpusQueryResult result = await service.query(<String>['ran']);
    expect(result.groups.single.kind, CorpusSourceKind.game);
    expect(
      result.groups.single.items.map((CorpusHit h) => h.text).toSet(),
      <String>{'The dog RAN home', 'A cat ran too'},
    );
    final CorpusHit hit = result.groups.single.items.firstWhere(
      (CorpusHit h) => h.text == 'The dog RAN home',
    );
    // pos = 这一行第一次出现的时刻（重绘不改它）。
    expect(hit.pos, 1000);
    expect(hit.highlights, <({int start, int length})>[(start: 8, length: 3)]);
    expect(hit.title, 'Some Game');

    // 同一句再来一次（回想 / 重读存档）：按 (游戏, 台词) 去重。
    service.feedGameLine(
      gameId: 'g1',
      lineKey: 'again',
      text: 'A cat ran too',
      atMs: 9000,
    );
    await service.flushGameLines();
    await settle();
    expect(await db.countGalgameTextLines('g1'), 2);
  });

  test('去抖落库留下最后一行（可能还在续写），停止捕获时才写', () async {
    await addGame('g1');
    final LibraryCorpusService quick = LibraryCorpusService(
      normalizer: normalizer,
      startDelay: const Duration(hours: 1),
      gameFlushDelay: const Duration(milliseconds: 10),
    );
    quick.start(database: db, directory: dir.path, isEnabled: () => enabled);
    quick
      ..feedGameLine(gameId: 'g1', lineKey: 'a', text: 'first line', atMs: 1)
      ..feedGameLine(gameId: 'g1', lineKey: 'b', text: 'second li', atMs: 2);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      (await db.select(db.galgameTextLines).get()).map(
        (GalgameTextLineRow r) => r.lineText,
      ),
      <String>['first line'],
    );
    quick.feedGameLine(
      gameId: 'g1',
      lineKey: 'b',
      text: 'second line',
      atMs: 3,
    );
    await quick.stop();
    expect(
      (await db.select(db.galgameTextLines).get()).map(
        (GalgameTextLineRow r) => r.lineText,
      ),
      <String>['first line', 'second line'],
    );
  });

  test('词典换了：游戏块按新口径重新分词；游戏删了台词与文档跟着删', () async {
    await addGame('g1');
    service.feedGameLine(
      gameId: 'g1',
      lineKey: 'a',
      text: 'Hello World',
      atMs: 1,
    );
    await service.flushGameLines();
    await settle();
    expect(await _gameDocs(service), <(String, String)>[('g1', 'dict-v1')]);

    normalizer.signature = 'dict-v2';
    service.scheduleReconcile();
    await settle();
    expect(await _gameDocs(service), <(String, String)>[('g1', 'dict-v2')]);
    final CorpusHit hit = (await service.query(<String>[
      'world',
    ])).groups.single.items.single;
    expect(hit.text, 'Hello World');
    expect(hit.pos, 1);

    await db.deleteGalgame('g1');
    await settle();
    expect(await db.countGalgameTextLines('g1'), 0, reason: '台词跟游戏走');
    expect(await _gameDocs(service), isEmpty);
  });

  test('L4 首版存在语料里的台词：对账时读回进表、换成派生文档，不丢', () async {
    await addGame('g1');
    // 用首版的形态直接写一份游戏文档（指纹没有 db: 前缀，台词只在语料里）。
    await service.debugPut(
      CorpusDocument(
        kind: CorpusSourceKind.game,
        key: 'g1',
        part: 0,
        title: 'Some Game',
        fingerprint: 'abcdef0123456789',
        normalizer: 'dict-v1',
        updatedAt: 1,
        sentences: const <CorpusSentence>[
          CorpusSentence(section: 0, pos: 42, len: 0, text: 'old line here'),
        ],
      ),
    );
    service.scheduleReconcile();
    await settle();
    final List<GalgameTextLineRow> rows = await db
        .select(db.galgameTextLines)
        .get();
    expect(rows.single.lineText, 'old line here');
    expect(rows.single.receivedAt, 42);
    final List<CorpusDocInfo> docs = await service.debugDocs(
      CorpusSourceKind.game,
    );
    expect(docs.single.fingerprint, startsWith('db:'));
    expect(
      (await service.query(<String>['old'])).groups.single.items.single.text,
      'old line here',
    );
  });

  test('语料目录里有坏文件：打开时丢掉、从台词表重建，查询照常', () async {
    await addGame('g1');
    await db.insertGalgameTextLines(
      'g1',
      const <({String text, int receivedAt})>[
        (text: 'broken index survives', receivedAt: 5),
      ],
    );
    await service.stop();
    final Directory fresh = Directory('${dir.path}/fresh')..createSync();
    File('${fresh.path}/garbage.fcd').writeAsBytesSync(<int>[1, 2, 3, 4]);
    service = LibraryCorpusService(
      normalizer: normalizer,
      startDelay: Duration.zero,
      debounce: const Duration(milliseconds: 1),
    );
    service.start(database: db, directory: fresh.path, isEnabled: () => true);
    await settle();
    expect(
      (await service.query(<String>[
        'survives',
      ])).groups.single.items.single.text,
      'broken index survives',
    );
    expect((await service.stats())!.droppedOnOpen, 1);
  });

  test('视频字幕：只认本地库里的视频，内容不变时不重复写', () async {
    final AudioCue cue = AudioCue()
      ..bookKey = 'v1'
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'Run, Forrest,\nrun'
      ..startMs = 61000
      ..endMs = 63000
      ..audioFileIndex = 0;
    // 不在 video_books 里的 uid（网页剧集 / 远端原盘）：跳过。
    service.feedVideoCues(
      bookUid: 'web:x',
      episodeIndex: 0,
      cues: <AudioCue>[cue],
    );
    await service.idle;
    expect((await service.query(<String>['run'])).isEmpty, isTrue);
  });

  test('关掉开关：查询回空、喂入不写', () async {
    enabled = false;
    service.feedGameLine(
      gameId: 'g1',
      lineKey: 'a',
      text: 'quiet please',
      atMs: 1,
    );
    await service.flushGameLines();
    enabled = true;
    expect((await service.query(<String>['quiet'])).isEmpty, isTrue);
  });

  test('弹窗回包：按模块分组、本地化标题、关掉的模块整组不出', () {
    final CorpusQueryResult result = CorpusQueryResult(
      total: 3,
      groups: <CorpusGroup>[
        CorpusGroup(
          kind: CorpusSourceKind.video,
          total: 2,
          items: <CorpusHit>[
            const CorpusHit(
              kind: CorpusSourceKind.video,
              key: 'v1',
              part: 2,
              title: 'Anime',
              section: 2,
              pos: 75000,
              len: 1000,
              text: 'run now',
              highlights: <({int start, int length})>[(start: 0, length: 3)],
            ),
          ],
        ),
        CorpusGroup(
          kind: CorpusSourceKind.game,
          total: 1,
          items: <CorpusHit>[
            const CorpusHit(
              kind: CorpusSourceKind.game,
              key: 'g1',
              part: 0,
              title: 'G',
              section: 0,
              pos: 5,
              len: 0,
              text: 'run!',
              highlights: <({int start, int length})>[],
            ),
          ],
        ),
      ],
    );
    final Map<String, Object?>? payload = librarySentencesPayload(
      result,
      const ModuleVisibility(<ModuleId>{ModuleId.video}),
    );
    final List<Object?> groups = payload!['groups']! as List<Object?>;
    expect(groups, hasLength(1));
    final Map<String, Object?> video = groups.single! as Map<String, Object?>;
    expect(video['kind'], CorpusSourceKind.video.code);
    final Map<String, Object?> item =
        (video['items']! as List<Object?>).single! as Map<String, Object?>;
    expect(item['hl'], <List<int>>[
      <int>[0, 3],
    ]);
    expect(item['source'], contains('1:15'));
    // ref 能原样解析回同一条定位（点击回到出处用）。
    final CorpusHit back = CorpusHit.tryFromJson(item['ref'])!;
    expect(back.kind, CorpusSourceKind.video);
    expect(back.key, 'v1');
    expect(back.section, 2);
    expect(back.pos, 75000);
    expect(librarySentenceSourceLabel(back), contains('Anime'));
  });
}
