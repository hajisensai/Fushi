// 存储位置的端到端加密（docs/specs/2026-10-25-srs-sync-v2-design.md §9）：开了加密的位置上只有密文；没有口令 /
// 口令不对的设备不碰这个位置；口令对的设备照常收敛。媒体放 media-e/，内容同样是密文。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e1';

/// 记下每个写进来的文件的字节，好检查位置上有没有明文。
class _RecordingStore extends SrsMemoryLocationStore {
  final Map<String, Uint8List> written = <String, Uint8List>{};

  @override
  Future<void> put(String path, Uint8List bytes) async {
    written[path] = bytes;
    await super.put(path, bytes);
  }
}

bool _contains(Uint8List hay, List<int> needle) {
  for (int i = 0; i + needle.length <= hay.length; i++) {
    int j = 0;
    while (j < needle.length && hay[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return true;
  }
  return false;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
  }

  Future<SrsSync2Report> round(
    SrsDbStore s,
    SrsLocationStore loc, {
    SrsLocationKey? key,
  }) => srsSync2Round(
    host: s,
    location: loc,
    locationId: 'loc',
    nowMs: () => s.now().$1,
    key: key,
  );

  test('开了加密：位置上无明文；没口令 / 口令错不同步；口令对才收敛', () async {
    final _RecordingStore loc = _RecordingStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    // 先明文同步一轮，再开加密：本机按新的进度身份把自己的段全部重传成密文。
    const String secret = '秘密の単語';
    final String note = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): secret,
      },
    );
    await round(a, loc);
    final SrsLocationKey enabling = await srsDeriveLocationKey(
      a,
      'correct horse',
      pendingEnable: true,
    );
    final SrsSync2Report enabled = await round(a, loc, key: enabling);
    expect(enabled.encryptionEnabled, isTrue);
    expect(enabled.encrypted, isTrue);
    final SrsLocationKey ka = enabling.enabled();

    final Map<String, Object?> meta =
        jsonDecode(utf8.decode((await loc.get('meta.json'))!))
            as Map<String, Object?>;
    expect((meta['kdf']! as Map)['check'], ka.check);
    // 开加密之后写的段里没有明文。
    final List<int> needle = utf8.encode(secret);
    loc.written.clear();
    await a.updateNote(
      note,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '$secret!',
      },
    );
    await round(a, loc, key: ka);
    final Iterable<MapEntry<String, Uint8List>> segs = loc.written.entries
        .where((MapEntry<String, Uint8List> e) => e.key.contains('/seg-'));
    expect(segs, isNotEmpty);
    for (final MapEntry<String, Uint8List> e in segs) {
      expect(_contains(e.value, needle), isFalse, reason: e.key);
    }

    final SrsSync2Report noKey = await round(b, loc);
    expect(noKey.error, kSrsSync2NeedsKey);
    expect(noKey.kdf?.saltHex, ka.kdf.saltHex);
    final SrsLocationKey wrong = await srsDeriveLocationKey(
      b,
      'wrong',
      kdf: noKey.kdf,
    );
    expect((await round(b, loc, key: wrong)).error, kSrsSync2WrongKey);
    final SrsLocationKey kb = await srsDeriveLocationKey(
      b,
      'correct horse',
      kdf: noKey.kdf,
    );
    expect(kb.keyHex, ka.keyHex);
    for (int i = 0; i < 2; i++) {
      await round(b, loc, key: kb);
      await round(a, loc, key: ka);
    }
    final SrsNoteView? got = await b.note(note);
    expect(got, isNotNull);
    expect(got!.field(srsLapisFieldId(kProfile, 'Expression')), '$secret!');
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
  });

  test('加密位置的媒体：media-e/ 下是密文，另一台用口令解出原文', () async {
    final _RecordingStore loc = _RecordingStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final Directory ma = Directory.systemTemp.createTempSync('srs_media_a_');
    final Directory mb = Directory.systemTemp.createTempSync('srs_media_b_');
    addTearDown(() {
      for (final Directory d in <Directory>[ma, mb]) {
        try {
          d.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄滞后。
        }
      }
    });
    final List<int> picture = utf8.encode('PNG-plain-bytes-marker');
    File('${ma.path}/pic.png').writeAsBytesSync(picture);
    await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '絵<img src="pic.png">',
      },
    );
    final SrsLocationKey ka = (await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    ));
    await round(a, loc, key: ka);
    await srsSyncMedia(
      location: loc,
      store: a,
      mediaRoot: ma,
      cipher: SrsMediaCipher(a, ka.keyHex),
    );
    final Uint8List sealed =
        loc.written[srsMediaContentPath(
          SrsMediaCipher(a, ka.keyHex).folder,
          srsMediaSha256(picture),
        )]!;
    expect(_contains(sealed, picture), isFalse);
    expect(
      loc.written.keys.where((String k) => k.startsWith('media/')),
      isEmpty,
    );

    // 名字 → 内容的绑定是操作：A 再发一轮，B 才知道 pic.png 是哪份内容。
    await round(a, loc, key: ka.enabled());
    await round(b, loc, key: ka.enabled());
    final SrsMediaSyncReport rb = await srsSyncMedia(
      location: loc,
      store: b,
      mediaRoot: mb,
      cipher: SrsMediaCipher(b, ka.keyHex),
    );
    expect(rb.downloaded, 1);
    expect(File('${mb.path}/pic.png').readAsBytesSync(), picture);
  });
}
