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
import 'package:path/path.dart' as p;
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

  test('S-9：大媒体文件到文件分块封装（FSM2），文件夹位置上流式传 / 收；坏一个字节整份拒收、不落地', () async {
    final Directory root = Directory.systemTemp.createTempSync('srs_loc_dir_');
    final SrsDirectoryLocationStore loc = SrsDirectoryLocationStore(root);
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final Directory ma = Directory.systemTemp.createTempSync('srs_media_a_');
    final Directory mb = Directory.systemTemp.createTempSync('srs_media_b_');
    addTearDown(() {
      for (final Directory d in <Directory>[root, ma, mb]) {
        try {
          d.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄滞后。
        }
      }
    });
    // 3 MiB + 零头：跨很多个 64 KiB 块，末块不满。
    final Uint8List movie = Uint8List(3 * 1024 * 1024 + 12345);
    for (int i = 0; i < movie.length; i++) {
      movie[i] = (i * 131 + (i >> 9)) & 0xff;
    }
    File('${ma.path}/clip.mp4').writeAsBytesSync(movie);
    await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '動[sound:clip.mp4]',
      },
    );
    final SrsLocationKey ka = await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    );
    await round(a, loc, key: ka);
    final SrsMediaCipher ca = SrsMediaCipher(a, ka.keyHex);
    final SrsMediaSyncReport ra = await srsSyncMedia(
      location: loc,
      store: a,
      mediaRoot: ma,
      cipher: ca,
    );
    expect(ra.uploaded, 1);
    final String sha = srsMediaSha256(movie);
    final File sealed = File(
      '${root.path}/${srsMediaContentPath(ca.folder, sha)}',
    );
    final Uint8List stored = sealed.readAsBytesSync();
    expect(ascii.decode(stored.sublist(0, 4)), 'FSM2');
    // 27 字节头 + 每 64 KiB 一个 16 字节 tag（含末块）。
    expect(stored.length, 27 + movie.length + (movie.length ~/ 65536 + 1) * 16);
    expect(
      _contains(stored.sublist(0, 4096), movie.sublist(100, 140)),
      isFalse,
    );
    // 位置目录里没有残留的临时文件。
    expect(
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => p.basename(f.path).startsWith('.srs2tmp-')),
      isEmpty,
    );

    await round(a, loc, key: ka.enabled());
    await round(b, loc, key: ka.enabled());
    // 先把位置上的密文坏一个字节（中间某块）：B 拒收、不落地；位置上那份不删（读者分不清是对象坏了还是这次
    // 传输坏了），只在旁边留可疑标记。
    final Uint8List bad = Uint8List.fromList(stored);
    bad[27 + 5 * 65552 + 7] ^= 0x40;
    sealed.writeAsBytesSync(bad);
    final SrsMediaSyncReport rejected = await srsSyncMedia(
      location: loc,
      store: b,
      mediaRoot: mb,
      cipher: SrsMediaCipher(b, ka.keyHex),
    );
    expect(rejected.rejected, contains('clip.mp4'));
    expect(rejected.downloaded, 0);
    expect(File('${mb.path}/clip.mp4').existsSync(), isFalse);
    expect(
      mb.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      isEmpty,
      reason: 'no half-written .download / .part files left behind',
    );
    expect(sealed.existsSync(), isTrue, reason: 'a reader never deletes');
    final File marker = File(
      '${root.path}/${srsMediaSuspectMarkerPath(ca.folder, sha)}',
    );
    expect(marker.existsSync(), isTrue);
    // 持有原文件的 A 下一轮看到标记，用核对过的原文覆盖重传、删掉标记；B 照常拿到原样字节。
    final SrsMediaSyncReport fixed = await srsSyncMedia(
      location: loc,
      store: a,
      mediaRoot: ma,
      cipher: ca,
    );
    expect(fixed.repaired, 1);
    expect(marker.existsSync(), isFalse);
    final SrsMediaSyncReport rb = await srsSyncMedia(
      location: loc,
      store: b,
      mediaRoot: mb,
      cipher: SrsMediaCipher(b, ka.keyHex),
    );
    expect(rb.downloaded, 1);
    expect(File('${mb.path}/clip.mp4').readAsBytesSync(), movie);
  });

  // 读者这把密钥解不开（第一块就认证不过，密钥证明不了是对的）：不怪对象——不记可疑、不写标记，持有者也不覆盖重传；
  // 读者按口令不对提示（undecryptable）。以前一律记可疑：密钥出问题的读者每轮记、持有者每轮覆盖，来回不停。
  test('加密位置：解不开（密钥证明不了）不记可疑、持有者不覆盖；每轮都不来回', () async {
    final Directory root = Directory.systemTemp.createTempSync('srs_loc_key_');
    final SrsDirectoryLocationStore loc = SrsDirectoryLocationStore(root);
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final Directory ma = Directory.systemTemp.createTempSync('srs_media_a_');
    final Directory mb = Directory.systemTemp.createTempSync('srs_media_b_');
    addTearDown(() {
      for (final Directory d in <Directory>[root, ma, mb]) {
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
    final SrsLocationKey ka = await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    );
    await round(a, loc, key: ka);
    final SrsMediaCipher ca = SrsMediaCipher(a, ka.keyHex);
    expect(
      (await srsSyncMedia(
        location: loc,
        store: a,
        mediaRoot: ma,
        cipher: ca,
      )).uploaded,
      1,
    );
    await round(a, loc, key: ka.enabled());
    await round(b, loc, key: ka.enabled());
    // 位置上那份换成不是按这个名字（AAD）封的密文：读者的密钥对它证明不了。
    final String sha = srsMediaSha256(picture);
    final File object = File(
      '${root.path}/${srsMediaContentPath(ca.folder, sha)}',
    );
    final Uint8List foreign = await ca.seal(
      'not-$sha',
      Uint8List.fromList(picture),
    );
    object.writeAsBytesSync(foreign);
    final File marker = File(
      '${root.path}/${srsMediaSuspectMarkerPath(ca.folder, sha)}',
    );
    for (int i = 0; i < 2; i++) {
      final SrsMediaSyncReport rb = await srsSyncMedia(
        location: loc,
        store: b,
        mediaRoot: mb,
        cipher: SrsMediaCipher(b, ka.keyHex),
      );
      expect(rb.rejected, contains('pic.png'), reason: 'round $i');
      expect(rb.undecryptable, <String>{'pic.png'}, reason: 'round $i');
      expect(rb.downloaded, 0);
      expect(File('${mb.path}/pic.png').existsSync(), isFalse);
      expect(marker.existsSync(), isFalse, reason: 'not suspect: round $i');
      final SrsMediaSyncReport ra = await srsSyncMedia(
        location: loc,
        store: a,
        mediaRoot: ma,
        cipher: ca,
      );
      expect(ra.repaired, 0, reason: 'the holder does not overwrite: round $i');
      expect(object.readAsBytesSync(), foreign);
    }
  });

  test('S-9：内存版 seal / open 与文件版同一格式，互相解得开', () async {
    final SrsDbStore a = await device('A');
    final SrsLocationKey ka = await srsDeriveLocationKey(
      a,
      'pw',
      pendingEnable: true,
    );
    final SrsMediaCipher c = SrsMediaCipher(a, ka.keyHex);
    final Directory dir = Directory.systemTemp.createTempSync('srs_seal_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final Uint8List plain = Uint8List.fromList(
      List<int>.generate(200000, (int i) => i % 251),
    );
    final Uint8List sealed = await c.seal('n', plain);
    expect(ascii.decode(sealed.sublist(0, 4)), 'FSM2');
    final File src = File('${dir.path}/s')..writeAsBytesSync(sealed);
    final File out = File('${dir.path}/o');
    expect((await c.openFile('n', src, out)).sha256, srsMediaSha256(plain));
    expect(out.readAsBytesSync(), plain);
    final File plainFile = File('${dir.path}/p')..writeAsBytesSync(plain);
    final File sealedFile = File('${dir.path}/q');
    expect(await c.sealFile('n', plainFile, sealedFile), srsMediaSha256(plain));
    expect(await c.open('n', sealedFile.readAsBytesSync()), plain);
    // AAD 绑定名字：换名解不开，文件版不留目标。
    expect(await c.open('m', sealed), isNull);
    final File none = File('${dir.path}/none');
    final SrsMediaOpened wrongName = await c.openFile('m', src, none);
    expect(wrongName.sha256, isNull);
    expect(wrongName.failure, SrsMediaOpenFailure.unauthenticated);
    expect(none.existsSync(), isFalse);
  });
}
