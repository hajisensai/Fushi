import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/anki/remote_mining_anki_repository.dart';
import 'package:hibiki/src/sync/forwarded_mine_payload.dart';
import 'package:hibiki/src/sync/hibiki_remote_mining_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';

/// 假发送器：捕获转发出去的 payload，返回预设响应，或抛鉴权错。
class _FakeSender implements RemoteMineSender {
  _FakeSender(this._response, {this.throwAuth = false});

  final Map<String, dynamic>? _response;
  final bool throwAuth;
  ForwardedMinePayload? captured;
  final List<List<String>> dupCalls = <List<String>>[];
  bool dupResult = false;

  @override
  Future<Map<String, dynamic>?> mineForward(
      ForwardedMinePayload payload) async {
    captured = payload;
    if (throwAuth) throw SyncAuthError('nope');
    return _response;
  }

  @override
  Future<bool> isDuplicate(
      {required String expression, required String reading}) async {
    dupCalls.add(<String>[expression, reading]);
    return dupResult;
  }
}

/// 假本地仓库：远端模式下 mineEntry/isDuplicate 绝不该落到它身上（落了就抛，验证不误操作本机）。
class _FakeLocal extends BaseAnkiRepository {
  bool fetchCalled = false;
  final List<String> createdDecks = <String>[];

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    fetchCalled = true;
    return AnkiFetchResult.success(
        decks: const <AnkiDeck>[], noteTypes: const <AnkiNoteType>[]);
  }

  @override
  Future<MineOutcome> mineEntry(
          {required String rawPayloadJson,
          required AnkiMiningContext context}) async =>
      throw StateError('local mineEntry must NOT run in remote mode');

  @override
  Future<bool> isDuplicate(String expression, String reading) async =>
      throw StateError('local isDuplicate must NOT run in remote mode');

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async {
    createdDecks.add(name);
    return true;
  }
}

void main() {
  group('RemoteMiningAnkiRepository', () {
    test('mineEntry 采集四类媒体并转发；映射 success', () async {
      final _FakeSender sender =
          _FakeSender(<String, dynamic>{'result': 'success'});
      final RemoteMiningAnkiRepository repo = RemoteMiningAnkiRepository(
        local: _FakeLocal(),
        client: sender,
        dictMediaLoader: (String dict, String path) =>
            Uint8List.fromList(<int>[9, 9]),
        fileByteLoader: (String path) async => path.contains('cover')
            ? Uint8List.fromList(<int>[1])
            : Uint8List.fromList(<int>[2]),
      );

      final String raw = jsonEncode(<String, dynamic>{
        'expression': '猫',
        'audio': r'C:\tmp\word.mp3', // 本地文件 → 搬字节
        'dictionaryMedia': jsonEncode(<dynamic>[
          <String, String>{
            'dictionary': 'D',
            'path': 'g/1.svg',
            'filename': 'hoshi_dict_0.svg',
          },
        ]),
      });

      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: raw,
        context: const AnkiMiningContext(
          sentence: '猫がいる',
          coverPath: '/x/cover.jpg',
          sasayakiAudioPath: '/x/audio.aac',
          source: AnkiMiningSource.book,
          bookTitleTag: 'B',
        ),
      );

      expect(outcome.result, MineResult.success);
      final ForwardedMinePayload cap = sender.captured!;
      expect(cap.rawPayloadJson, raw); // 逐字转发（服务端渲染）
      expect(cap.sentence, '猫がいる');
      expect(cap.source, 'book');
      expect(cap.bookTitleTag, 'B');
      expect(cap.coverBytes, <int>[1]);
      expect(cap.coverExt, 'jpg');
      expect(cap.sentenceAudioBytes, <int>[2]);
      expect(cap.sentenceAudioExt, 'aac');
      expect(cap.wordAudioBytes, <int>[2]);
      expect(cap.wordAudioExt, 'mp3');
      expect(cap.dictionaryMedia.single.dictionary, 'D');
      expect(cap.dictionaryMedia.single.path, 'g/1.svg');
      expect(cap.dictionaryMedia.single.bytes, <int>[9, 9]);
    });

    test('http 单词音频不搬字节（留给服务端下载）', () async {
      final _FakeSender sender =
          _FakeSender(<String, dynamic>{'result': 'success'});
      final RemoteMiningAnkiRepository repo = RemoteMiningAnkiRepository(
        local: _FakeLocal(),
        client: sender,
        dictMediaLoader: (String d, String p) => null,
        fileByteLoader: (String p) async => null,
      );
      await repo.mineEntry(
        rawPayloadJson: jsonEncode(
            <String, dynamic>{'expression': '猫', 'audio': 'https://x/a.mp3'}),
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(sender.captured!.wordAudioBytes, isNull);
    });

    test('映射 duplicate/notConfigured/error/不可达', () async {
      Future<MineResult> run(Map<String, dynamic>? resp) async {
        final RemoteMiningAnkiRepository repo = RemoteMiningAnkiRepository(
          local: _FakeLocal(),
          client: _FakeSender(resp),
          fileByteLoader: (String p) async => null,
          dictMediaLoader: (String d, String p) => null,
        );
        final MineOutcome o = await repo.mineEntry(
            rawPayloadJson: '{}',
            context: const AnkiMiningContext(sentence: ''));
        return o.result;
      }

      expect(await run(<String, dynamic>{'result': 'duplicate'}),
          MineResult.duplicate);
      expect(await run(<String, dynamic>{'result': 'notConfigured'}),
          MineResult.notConfigured);
      expect(await run(<String, dynamic>{'result': 'error', 'message': 'boom'}),
          MineResult.error);
      expect(await run(null), MineResult.error); // 无可达主机
    });

    test('鉴权失败 → error outcome', () async {
      final RemoteMiningAnkiRepository repo = RemoteMiningAnkiRepository(
        local: _FakeLocal(),
        client: _FakeSender(null, throwAuth: true),
        fileByteLoader: (String p) async => null,
        dictMediaLoader: (String d, String p) => null,
      );
      final MineOutcome o = await repo.mineEntry(
          rawPayloadJson: '{}', context: const AnkiMiningContext(sentence: ''));
      expect(o.result, MineResult.error);
    });

    test('isDuplicate 走远端发送器', () async {
      final _FakeSender sender = _FakeSender(null)..dupResult = true;
      final RemoteMiningAnkiRepository repo =
          RemoteMiningAnkiRepository(local: _FakeLocal(), client: sender);
      expect(await repo.isDuplicate('猫', 'ねこ'), isTrue);
      expect(sender.dupCalls.single, <String>['猫', 'ねこ']);
    });

    test('配置类方法委派本地（设置页仍能配置本地 Anki）', () async {
      final _FakeLocal local = _FakeLocal();
      final RemoteMiningAnkiRepository repo =
          RemoteMiningAnkiRepository(local: local, client: _FakeSender(null));
      await repo.fetchConfiguration();
      expect(local.fetchCalled, isTrue);
      await repo.createDeck('Deck::Sub');
      expect(local.createdDecks.single, 'Deck::Sub');
    });

    test('覆盖/查看类方法保留基类降级（不误操作本机 Anki）', () async {
      final RemoteMiningAnkiRepository repo = RemoteMiningAnkiRepository(
          local: _FakeLocal(), client: _FakeSender(null));
      expect(await repo.findOverwriteTargetNoteId('a', 'b'), isNull);
      expect(await repo.findMatchingNotes('a', 'b'), isEmpty);
      expect(await repo.noteFields(1), isNull);
      expect(await repo.openNoteInAnki(1), isFalse);
      final MineOutcome up = await repo.updateMinedNote(
          noteId: 1,
          rawPayloadJson: '{}',
          context: const AnkiMiningContext(sentence: ''));
      expect(up.result, MineResult.error);
    });
  });
}
