// 字幕书与远端（Audiobookshelf）音频的绑定：领域模型编解码、仓储读写、损坏行降级、
// 删字幕书时同事务清绑定。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

const List<RemoteAudioTrack> _tracks = <RemoteAudioTrack>[
  RemoteAudioTrack(
    ino: '10',
    startOffsetMs: 0,
    durationMs: 600500,
    mimeType: 'audio/mpeg',
    sizeBytes: 5000,
    filename: 'a.mp3',
  ),
  RemoteAudioTrack(ino: '11', startOffsetMs: 600500, durationMs: 399500),
];

RemoteAudioBinding _binding({
  String uid = 'srtbook_1',
  String? episodeId,
  List<RemoteAudioTrack> tracks = _tracks,
  String origin = RemoteAudioBinding.subtitleOriginLocal,
}) => RemoteAudioBinding(
  srtBookUid: uid,
  provider: RemoteAudioBinding.providerAudiobookshelf,
  serverConfigId: 'srv',
  itemId: 'item_1',
  episodeId: episodeId,
  tracks: tracks,
  subtitleOrigin: origin,
  createdAt: 100,
  updatedAt: 100,
);

void main() {
  late FushiDatabase db;
  late RemoteAudioBindingRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = RemoteAudioBindingRepository(db);
  });
  tearDown(() => db.close());

  group('音轨编解码', () {
    test('往返保持偏移 / 时长 / 可选字段', () {
      final List<RemoteAudioTrack>? decoded = RemoteAudioBinding.decodeTracks(
        RemoteAudioBinding.encodeTracks(_tracks),
      );
      expect(decoded, _tracks);
      expect(decoded![0].mimeType, 'audio/mpeg');
      expect(decoded[0].sizeBytes, 5000);
      expect(decoded[0].filename, 'a.mp3');
      expect(decoded[1].mimeType, isNull);
    });

    test('坏 JSON / 空表 / 有一条解不出 → null（整体作废，不带缺轨的偏移表）', () {
      expect(RemoteAudioBinding.decodeTracks('not json'), isNull);
      expect(RemoteAudioBinding.decodeTracks('{}'), isNull);
      expect(RemoteAudioBinding.decodeTracks('[]'), isNull);
      expect(
        RemoteAudioBinding.decodeTracks(
          '[{"ino":"1","startOffsetMs":0,"durationMs":5},{"ino":"2"}]',
        ),
        isNull,
      );
    });

    test('sameTracksAs：ino / 偏移 / 时长任一变化都算不同（服务器重扫指纹）', () {
      final RemoteAudioBinding binding = _binding();
      expect(binding.sameTracksAs(_tracks.toList()), isTrue);
      expect(binding.sameTracksAs(_tracks.take(1).toList()), isFalse);
      expect(
        binding.sameTracksAs(<RemoteAudioTrack>[
          _tracks[0],
          const RemoteAudioTrack(
            ino: '11',
            startOffsetMs: 600500,
            durationMs: 400000,
          ),
        ]),
        isFalse,
      );
    });

    test('serverSubtitleIno：只有 server:<ino> 才有值', () {
      expect(_binding().serverSubtitleIno, isNull);
      expect(
        _binding(
          origin: RemoteAudioBinding.subtitleOriginServer('20'),
        ).serverSubtitleIno,
        '20',
      );
    });
  });

  group('仓储', () {
    test('没有绑定 → null', () async {
      expect(await repo.get('nope'), isNull);
      expect(await repo.listAll(), isEmpty);
    });

    test('保存后读回；再次保存是整行覆盖（同一本书至多一条）', () async {
      await repo.save(_binding(episodeId: 'ep_1'));
      final RemoteAudioBinding? loaded = await repo.get('srtbook_1');
      expect(loaded, isNotNull);
      expect(loaded!.episodeId, 'ep_1');
      expect(loaded.tracks, _tracks);
      expect(loaded.subtitleOrigin, RemoteAudioBinding.subtitleOriginLocal);

      await repo.save(
        _binding(
          tracks: _tracks.take(1).toList(),
          origin: RemoteAudioBinding.subtitleOriginServer('20'),
        ),
      );
      final RemoteAudioBinding? replaced = await repo.get('srtbook_1');
      expect(replaced!.tracks, hasLength(1));
      expect(replaced.episodeId, isNull);
      expect(replaced.serverSubtitleIno, '20');
      expect(await repo.listAll(), hasLength(1));
    });

    test('listAll 按 uid 索引，并跳过损坏的行', () async {
      await repo.save(_binding(uid: 'good'));
      await db.upsertRemoteAudioBinding(
        RemoteAudioBindingsCompanion.insert(
          srtBookUid: 'broken',
          provider: 'audiobookshelf',
          serverConfigId: 'srv',
          itemId: 'item_2',
          tracksJson: '[{"ino":"1"}]',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      expect(await repo.get('broken'), isNull, reason: '损坏行 = 没有绑定');
      expect((await repo.listAll()).keys, <String>['good']);
    });

    test('findForItem：按（服务器、条目、单集）精确命中，别的组合不命中', () async {
      await repo.save(_binding(uid: 'book'));
      await repo.save(_binding(uid: 'episode', episodeId: 'ep_1'));
      expect(
        (await repo.findForItem(
          serverConfigId: 'srv',
          itemId: 'item_1',
        ))?.srtBookUid,
        'book',
      );
      expect(
        (await repo.findForItem(
          serverConfigId: 'srv',
          itemId: 'item_1',
          episodeId: 'ep_1',
        ))?.srtBookUid,
        'episode',
      );
      expect(
        await repo.findForItem(serverConfigId: 'other', itemId: 'item_1'),
        isNull,
      );
      expect(
        await repo.findForItem(
          serverConfigId: 'srv',
          itemId: 'item_1',
          episodeId: 'ep_2',
        ),
        isNull,
      );
    });

    test('delete 返回删掉的行数', () async {
      await repo.save(_binding());
      expect(await repo.delete('srtbook_1'), 1);
      expect(await repo.delete('srtbook_1'), 0);
    });
  });

  test('删除字幕书的同事务清掉绑定（逻辑外键没有级联）', () async {
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srtbook_1',
        title: 'Fables',
        srtPath: '/x/fables.srt',
        importedAt: 1,
      ),
    );
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srtbook_2',
        title: 'Other',
        srtPath: '/x/other.srt',
        importedAt: 1,
        bookKey: const Value<String>(''),
      ),
    );
    await repo.save(_binding(uid: 'srtbook_1'));
    await repo.save(_binding(uid: 'srtbook_2'));

    expect(await db.deleteSrtBookByUid('srtbook_1'), 1);

    expect(await repo.get('srtbook_1'), isNull);
    expect(await repo.get('srtbook_2'), isNotNull, reason: '别的书的绑定不受影响');
  });
}
