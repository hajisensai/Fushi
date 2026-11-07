// 曲库歌词搜索的语料编排（LibraryCorpusService）与「我库里的例句」下架后的存量清理：
// 真 fushi_corpus 原生库 + 真内存库，只把词典词元换成确定性的假实现（空格分词、小写 =
// 词典形），这样调度 / 增量 / 清理能在没有词典原生库的环境里跑。原生 fushi_corpus / fushi_compute 是硬依赖：找不到库直接红。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/corpus/library_corpus_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_music/fushi_music.dart';

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

void main() {
  late Directory dir;
  late FushiDatabase db;
  late FakeNormalizer normalizer;
  late LibraryCorpusService service;

  LibraryCorpusService newService() => LibraryCorpusService(
    normalizer: normalizer,
    startDelay: Duration.zero,
    debounce: const Duration(milliseconds: 1),
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('fushi_corpus_service');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    normalizer = FakeNormalizer();
    service = newService();
    service.start(database: db, directory: dir.path);
    // 让 startDelay 的计时器跑完首轮清理与对账。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.idle;
  });

  tearDown(() async {
    await service.stop();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 等表变化的去抖对账与它排出的喂入任务都跑完。
  Future<void> settle() async {
    for (int i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await service.idle;
    }
  }

  /// 换一个服务实例重新打开同一个语料目录（模拟升级后的下次启动）。
  Future<void> restart(String directory) async {
    await service.stop();
    service = newService();
    service.start(database: db, directory: directory);
    await settle();
  }

  Future<void> addTrack(String uid) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: '/m/$uid.flac',
          title: 'Title $uid',
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      );

  Future<void> addLyrics(
    String uid,
    String source,
    String srt, {
    int updatedAt = 1,
  }) async {
    final Uint8List raw = utf8.encode(srt);
    final LyricTimeline t = FushiLyrics.parse(raw, hint: 'srt');
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: uid,
            source: source,
            format: 'srt',
            raw: raw,
            timelineCache: Value<Uint8List?>(encodeLyricTimeline(t)),
            timelineVersion: Value<int>(FushiLyrics.parserVersion),
            updatedAt: updatedAt,
          ),
        );
  }

  /// 旧版本「我库里的例句」写进语料目录的一份文档。
  CorpusDocument legacyDoc(CorpusSourceKind kind, String key, String text) =>
      CorpusDocument(
        kind: kind,
        key: key,
        part: kind == CorpusSourceKind.book ? -1 : 0,
        title: 'Legacy $key',
        fingerprint: 'legacy',
        normalizer: 'dict-v1',
        updatedAt: 1,
        sentences: <CorpusSentence>[
          CorpusSentence(section: 0, pos: 0, len: 0, text: text),
        ],
      );

  /// 语料目录里的文档文件数（一文档一个 `.fcd`）。
  int docFiles(String directory) => Directory(directory)
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.fcd'))
      .length;

  group('下架「我库里的例句」：清掉书 / 视频 / 游戏的存量文档（反馈 4S2_J80DfK）', () {
    test('启动时删掉三类残留文档与磁盘文件，歌词文档与歌词搜索不受影响；再启动是空操作', () async {
      await addTrack('t1');
      await addLyrics(
        't1',
        'asr',
        '1\n00:00:01,000 --> 00:00:02,000\nthe dog ran home\n',
      );
      await settle();
      await service.debugPut(
        legacyDoc(CorpusSourceKind.book, 'b1', 'the dog in a book'),
      );
      await service.debugPut(
        legacyDoc(CorpusSourceKind.video, 'v1', 'the dog in a video'),
      );
      await service.debugPut(
        legacyDoc(CorpusSourceKind.game, 'g1', 'the dog in a game'),
      );
      expect(docFiles(dir.path), 4);

      await restart(dir.path);

      for (final CorpusSourceKind kind in LibraryCorpusService.retiredKinds) {
        expect(await service.debugDocs(kind), isEmpty, reason: kind.name);
      }
      expect(
        (await service.debugDocs(
          CorpusSourceKind.music,
        )).map((CorpusDocInfo d) => d.key),
        <String>['t1'],
      );
      expect(docFiles(dir.path), 1, reason: '删文档要连磁盘文件一起删，才真正腾出空间');
      expect(
        (await service.searchText(
          'dog',
          kind: CorpusSourceKind.music,
        )).map((CorpusHit h) => h.text),
        <String>['the dog ran home'],
      );

      // 幂等：没有残留时再启动什么都不删。
      await restart(dir.path);
      expect(docFiles(dir.path), 1);
      expect((await service.stats())!.docs, 1);
    });

    test('没装词典（分不出词、不对账歌词）时照样清残留', () async {
      await service.debugPut(
        legacyDoc(CorpusSourceKind.book, 'b1', 'orphan sentence'),
      );
      normalizer.signature = null;
      await restart(dir.path);
      expect(await service.debugDocs(CorpusSourceKind.book), isEmpty);
      expect(docFiles(dir.path), 0);
    });

    test('只有歌词表触发增量：书 / 视频 / 游戏的来源表变化不再喂入', () async {
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'Some Game',
          exePath: '/g/g1.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      await db.insertGalgameTextLines(
        'g1',
        const <({String text, int receivedAt})>[
          (text: 'hooked line', receivedAt: 5),
        ],
      );
      await settle();
      expect(await service.debugDocs(CorpusSourceKind.game), isEmpty);
      expect(docFiles(dir.path), 0);
    });
  });

  test('语料目录里有坏文件：打开时丢掉、从歌词表重建，搜索照常', () async {
    await addTrack('t1');
    await addLyrics(
      't1',
      'asr',
      '1\n00:00:01,000 --> 00:00:02,000\nbroken index survives\n',
    );
    final Directory fresh = Directory('${dir.path}/fresh')..createSync();
    File('${fresh.path}/garbage.fcd').writeAsBytesSync(<int>[1, 2, 3, 4]);
    await restart(fresh.path);
    expect(
      (await service.searchText(
        'survives',
        kind: CorpusSourceKind.music,
      )).single.text,
      'broken index survives',
    );
    expect((await service.stats())!.droppedOnOpen, 1);
  });

  group('曲库歌词文本搜索（searchText）', () {
    test('句子须含查询文本的全部词；命中带曲目与行时间', () async {
      await addTrack('t1');
      await addTrack('t2');
      await addLyrics(
        't1',
        'asr',
        '1\n00:00:01,000 --> 00:00:02,000\nthe dog ran home\n\n'
            '2\n00:00:05,000 --> 00:00:06,000\nthe dog slept\n',
      );
      await addLyrics(
        't2',
        'asr',
        '1\n00:00:03,000 --> 00:00:04,000\na cat ran away\n',
      );
      await settle();
      final List<CorpusHit> hits = await service.searchText(
        'Dog RAN',
        kind: CorpusSourceKind.music,
      );
      expect(
        hits.map((CorpusHit h) => (h.key, h.pos, h.text)),
        <(String, int, String)>[('t1', 1000, 'the dog ran home')],
      );
      expect(
        await service.searchText('nothing here', kind: CorpusSourceKind.music),
        isEmpty,
      );
    });

    test('同一首有 sidecar 与生成字幕：索引的是歌词页会显示的 sidecar', () async {
      await addTrack('t1');
      await addLyrics(
        't1',
        'sidecar',
        '1\n00:00:01,000 --> 00:00:02,000\nfrom sidecar file\n',
      );
      await addLyrics(
        't1',
        'asr',
        '1\n00:00:01,000 --> 00:00:02,000\nfrom generated asr\n',
        updatedAt: 99,
      );
      await settle();
      expect(
        (await service.searchText(
          'sidecar',
          kind: CorpusSourceKind.music,
        )).map((CorpusHit h) => h.text),
        <String>['from sidecar file'],
      );
      expect(
        await service.searchText('generated', kind: CorpusSourceKind.music),
        isEmpty,
        reason: '旧判据「最近更新的」会挑中 asr，与歌词页对不上',
      );
    });

    test('corpusTermKeys：取出全部词典形、去重保序', () {
      expect(
        corpusTermKeys(fakeTerms(<String>['The dog the DOG ran'])),
        <String>['the', 'dog', 'ran'],
      );
    });
  });
}
