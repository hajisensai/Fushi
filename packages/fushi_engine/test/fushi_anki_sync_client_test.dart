import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:test/test.dart';

/// 假 helper：读请求行，按 [respond] 回一行。
class _FakeHelper {
  _FakeHelper(this.respond) {
    _in.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
      String line,
    ) {
      final Map<String, Object?> req = jsonDecode(line) as Map<String, Object?>;
      requests.add(req);
      final Object? reply = respond(req);
      if (reply == null) return; // 不回：模拟 helper 卡住 / 退出
      _out.add(
        utf8.encode(
          '${jsonEncode(<String, Object?>{'id': req['id'], ...reply as Map<String, Object?>})}\n',
        ),
      );
    });
  }

  final Object? Function(Map<String, Object?> request) respond;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final StreamController<List<int>> _in = StreamController<List<int>>();
  final StreamController<List<int>> _out = StreamController<List<int>>();

  FushiAnkiSyncClient client() => FushiAnkiSyncClient.fromStreams(
    stdin: IOSink(_in.sink),
    stdout: _out.stream,
  );

  /// 模拟 helper 进程退出（stdout 关闭）。
  Future<void> exit() => _out.close();
}

Map<String, Object?> _ok(Object? result) => <String, Object?>{
  'ok': true,
  'result': result,
};

void main() {
  test('请求按行发出、带递增 id，回复按 id 配对', () async {
    final _FakeHelper h = _FakeHelper((Map<String, Object?> r) {
      return switch (r['cmd']) {
        'login' => _ok(<String, Object?>{'hkey': 'H'}),
        'open' => _ok(<String, Object?>{'created': true}),
        'add_note' => _ok(<String, Object?>{
          'note_id': 1700000000000,
          'media': <String>[],
        }),
        _ => _ok(<String, Object?>{}),
      };
    });
    final FushiAnkiSyncClient c = h.client();

    expect(
      await c.login(endpoint: 'http://nas:8080/', username: 'u', password: 'p'),
      'H',
    );
    expect(await c.open('/data/c.anki2'), isTrue);
    expect(
      await c.addNote(
        notetype: 'Basic',
        deck: 'Fushi',
        fields: <String>['猫', 'cat'],
        tags: <String>['fushi'],
        media: <(String, String)>[('a.jpg', '/tmp/a.jpg')],
      ),
      1700000000000,
    );

    expect(h.requests.map((Map<String, Object?> r) => r['id']), <int>[0, 1, 2]);
    expect(h.requests[0]['endpoint'], 'http://nas:8080/');
    expect(h.requests[2]['media'], <Object?>[
      <Object?>['a.jpg', '/tmp/a.jpg'],
    ]);
  });

  test('helper 报错 → FushiAnkiSyncException，后续请求照常', () async {
    final _FakeHelper h = _FakeHelper((Map<String, Object?> r) {
      if (r['cmd'] == 'list_meta') {
        return <String, Object?>{'ok': false, 'error': 'collection not open'};
      }
      return _ok(<String, Object?>{'duplicate': true});
    });
    final FushiAnkiSyncClient c = h.client();

    await expectLater(
      c.listMeta(),
      throwsA(
        isA<FushiAnkiSyncException>().having(
          (FushiAnkiSyncException e) => e.message,
          'message',
          contains('collection not open'),
        ),
      ),
    );
    expect(await c.isDuplicate(notetype: 'Basic', firstField: '猫'), isTrue);
  });

  test('服务器要求整库上传 → fullSyncBlocked（Fushi 永不上传）', () async {
    final _FakeHelper h = _FakeHelper(
      (_) =>
          _ok(<String, Object?>{'status': 'full_sync_blocked', 'reason': 'x'}),
    );
    final AnkiSyncResult r = await h.client().sync(hkey: 'H');
    expect(r.status, AnkiSyncStatus.fullSyncBlocked);
  });

  test('整库下载与换地址如实带回', () async {
    final _FakeHelper h = _FakeHelper(
      (_) => _ok(<String, Object?>{
        'status': 'ok',
        'full_download': true,
        'new_endpoint': 'https://nas2/',
        'server_message': '',
      }),
    );
    final AnkiSyncResult r = await h.client().sync(hkey: 'H');
    expect(r.status, AnkiSyncStatus.ok);
    expect(r.fullDownload, isTrue);
    expect(r.newEndpoint, 'https://nas2/');
  });

  test('helper 中途退出：在途与之后的请求都失败，不会挂死', () async {
    final _FakeHelper h = _FakeHelper((_) => null);
    final FushiAnkiSyncClient c = h.client();
    final Future<AnkiSyncMeta> inFlight = c.listMeta();
    await Future<void>.delayed(Duration.zero);
    await h.exit();

    await expectLater(inFlight, throwsA(isA<FushiAnkiSyncException>()));
    await expectLater(c.version(), throwsA(isA<FushiAnkiSyncException>()));
  });

  // 真实二进制：设 FUSHI_ANKI_SYNC_BIN 指向 native/fushi_anki_sync 的构建产物才跑。
  final String? bin = Platform.environment['FUSHI_ANKI_SYNC_BIN'];
  test(
    '真实 helper：如实标识为 fushi，并能新建 / 打开 collection',
    () async {
      final Directory tmp = await Directory.systemTemp.createTemp('anki_sync');
      final FushiAnkiSyncClient c = await FushiAnkiSyncClient.start(bin!);
      try {
        final String client = await c.version();
        expect(client, startsWith('fushi,'));
        expect(client, contains('(anki 26.09.3)'));
        expect(client, isNot(startsWith('anki,')));

        final String path = '${tmp.path}/collection.anki2';
        expect(await c.open(path), isTrue);
        final AnkiSyncMeta meta = await c.listMeta();
        expect(
          meta.notetypes.map((AnkiSyncNotetype n) => n.name),
          contains('Basic'),
        );
        await c.close();
        expect(await c.open(path), isFalse, reason: '第二次打开是已存在的库');
      } finally {
        await c.dispose();
        await tmp.delete(recursive: true);
      }
    },
    skip: bin == null ? 'FUSHI_ANKI_SYNC_BIN 未设置' : false,
  );

  test(
    '真实 helper：find_notes 与查重同一判据（去 HTML、通配符按字面、不做子串匹配）',
    () async {
      final Directory tmp = await Directory.systemTemp.createTemp('anki_sync');
      final FushiAnkiSyncClient c = await FushiAnkiSyncClient.start(bin!);
      try {
        await c.open('${tmp.path}/collection.anki2');
        final int a = await c.addNote(
          notetype: 'Basic',
          deck: 'Mining',
          fields: <String>['<b>猫_*</b>', 'x'],
        );
        final int b = await c.addNote(
          notetype: 'Basic',
          deck: 'Mining',
          fields: <String>['猫_*', 'y'],
          tags: <String>['fushi'],
        );
        await c.addNote(
          notetype: 'Basic',
          deck: 'Mining',
          fields: <String>['猫又', 'z'],
        );

        final List<AnkiSyncNoteHit> hits = await c.findNotes(
          notetype: 'Basic',
          firstField: '猫_*',
        );
        expect(hits.map((AnkiSyncNoteHit h) => h.noteId), <int>[b, a],
            reason: '两张都命中，新卡在前');
        expect(hits.first.preview, '猫_*');
        expect(
          await c.findNotes(notetype: 'Basic', firstField: '猫'),
          isEmpty,
          reason: '「猫」不能命中「猫_*」「猫又」',
        );
        expect(
          await c.isDuplicate(notetype: 'Basic', firstField: '猫_*'),
          isTrue,
        );
        expect(
          await c.isDuplicate(notetype: 'Basic', firstField: '猫'),
          isFalse,
        );
      } finally {
        await c.dispose();
        await tmp.delete(recursive: true);
      }
    },
    skip: bin == null ? 'FUSHI_ANKI_SYNC_BIN 未设置' : false,
  );
}
