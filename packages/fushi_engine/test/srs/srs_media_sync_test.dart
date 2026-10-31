// SRS 媒体同步（srs_media_sync.dart，docs/specs/2026-10-25-srs-sync-v2-design.md §6.4、§10.5）：集合根下内容寻址的
// `media/<sha256 前 2 位>/<sha256>`，本机文件名经日志里的绑定映射到内容（绑定是操作，随段同步）；缺的从位置下载
// 并校验哈希、位置缺的上传；被删笔记的媒体保留 90 天后才从位置上清，删除只凭正面证据（本机不认识的文件不删）；
// 归档位置永不删；旧布局（按名字存的 `media/<名字>`、按写入者分目录）只读兜底。
import 'dart:async';
import 'dart:convert' show Encoding, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_migration.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000cc';
const int kDay = 24 * 60 * 60 * 1000;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  int t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;
    root = Directory.systemTemp.createTempSync('fushi_srs_media_');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  Directory mediaDir(String name) =>
      Directory(p.join(root.path, name))..createSync(recursive: true);

  void writeMedia(Directory d, String name, List<int> bytes) =>
      File(p.join(d.path, name)).writeAsBytesSync(bytes);

  Future<String> addNote(SrsDbStore s, String expr, String picture) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expr,
        srsLapisFieldId(kProfile, 'Picture'): picture,
      },
    );
  }

  Future<SrsMediaSyncReport> media(
    SrsDbStore s,
    SrsLocationStore loc,
    Directory dir, {
    bool archive = false,
    String? locationId,
  }) => srsSyncMedia(
    location: loc,
    store: s,
    mediaRoot: dir,
    archive: archive,
    locationId: locationId,
  );

  /// 位置上内容目录里有哪些内容（sha256）。
  Set<String> remoteMedia(SrsMemoryLocationStore loc) => <String>{
    for (final String path in loc.files.keys)
      if (path.startsWith('$kSrsMediaFolder/') && path.split('/').length == 3)
        path.split('/').last,
  };
  String sha(List<int> bytes) => srsMediaSha256(bytes);
  String at(List<int> bytes) =>
      srsMediaContentPath(kSrsMediaFolder, sha(bytes));

  test('按内容名上传 / 下载；位置上丢了的由仍持有它的设备补传', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    writeMedia(mediaA, 'cat.png', <int>[1, 2, 3]);
    writeMedia(mediaA, 'meow.mp3', <int>[4, 5]);
    t += 1000;
    await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '猫',
        srsLapisFieldId(kProfile, 'Picture'): '<img src="cat.png">',
        srsLapisFieldId(kProfile, 'ExpressionAudio'): '[sound:meow.mp3]',
      },
    );
    await srsSyncPeers(<SrsDbStore>[a, b], loc);

    final SrsMediaSyncReport ra = await media(a, loc, mediaA);
    expect(ra.uploaded, 2);
    expect(remoteMedia(loc), <String>{
      sha(<int>[1, 2, 3]),
      sha(<int>[4, 5]),
    });
    // 名字 → 内容的绑定是操作：随下一轮同步到 B。
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    final SrsMediaSyncReport rb = await media(b, loc, mediaB);
    expect(rb.downloaded, 2);
    expect(rb.missing, isEmpty);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect((await media(a, loc, mediaA)).uploaded, 0, reason: '位置上已有，不重传');

    // 位置上的文件丢了（换了网盘 / 被别的工具删了）：持有它的设备下一轮补传，第三台照常拿到。
    loc.files.remove(at(<int>[1, 2, 3]));
    expect((await media(b, loc, mediaB)).uploaded, 1);
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    final Directory mediaC = mediaDir('c');
    expect((await media(c, loc, mediaC)).downloaded, 2);
  });

  test('引用了但位置与本机都没有：报缺失，等持有它的设备上线', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    await addNote(a, '犬', '<img src="dog.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    final SrsMediaSyncReport r = await media(b, loc, mediaDir('b'));
    expect(r.downloaded, 0);
    expect(r.missing, <String>{'dog.png'});
  });

  test('被删笔记的媒体：90 天内位置上保留、还能下载；过期后清掉独占的，共享的与本机不认识的不删', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    writeMedia(mediaA, 'only.png', <int>[1]);
    writeMedia(mediaA, 'shared.png', <int>[2]);
    final String gone = await addNote(
      a,
      '雪',
      '<img src="only.png"><img src="shared.png">',
    );
    await addNote(a, '雨', '<img src="shared.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect((await media(a, loc, mediaA)).uploaded, 2);
    // 别的设备的新笔记的媒体：本机还没收到那条笔记，不认识它。
    await loc.put(at(<int>[9]), Uint8List.fromList(<int>[9]));

    t += 1000;
    await a.deleteNote(gone);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    t += 89 * kDay;
    SrsMediaSyncReport r = await media(a, loc, mediaA);
    expect(r.deleted, 0, reason: '保留期内不删');
    expect(remoteMedia(loc), contains(sha(<int>[1])));
    // 保留期内恢复笔记媒体还在：新设备照样下载被删笔记的媒体。
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    final Directory mediaC = mediaDir('c');
    expect((await media(c, loc, mediaC)).downloaded, 2);
    expect(File(p.join(mediaC.path, 'only.png')).existsSync(), isTrue);

    t += 2 * kDay;
    r = await media(a, loc, mediaA);
    expect(r.deleted, 1);
    expect(remoteMedia(loc), <String>{
      sha(<int>[2]),
      sha(<int>[9]),
    });
    expect(
      (await media(b, loc, mediaDir('b'))).uploaded,
      0,
      reason: '看得到删除的设备不会把过期的文件再传上来',
    );
    expect(remoteMedia(loc), isNot(contains(sha(<int>[1]))));
  });

  test('归档位置永不删：过期的媒体照样留着', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final SrsDbStore a = await device('a');
    writeMedia(mediaA, 'only.png', <int>[1]);
    final String gone = await addNote(a, '雪', '<img src="only.png">');
    expect((await media(a, loc, mediaA, archive: true)).uploaded, 1);
    t += 1000;
    await a.deleteNote(gone);
    t += 365 * kDay;
    final SrsMediaSyncReport r = await media(a, loc, mediaA, archive: true);
    expect(r.deleted, 0);
    expect(remoteMedia(loc), <String>{
      sha(<int>[1]),
    });
    // 同一份过期状态对普通同步 / 媒体位置就会清。
    expect((await media(a, loc, mediaA)).deleted, 1);
  });

  test('旧格式（按写入者分目录）的媒体由一次性迁移搬进内容目录、补上绑定，绑定发布后逐个删旧文件', () async {
    // 2026-10-30 断代：媒体对账不再读写入者目录（没有兜底读者），只有 srsPrepareLocation 搬一次。
    final Directory remote = Directory(p.join(root.path, 'remote'))
      ..createSync();
    final LocalDirectoryAssetStore backend = LocalDirectoryAssetStore(remote);
    final File legacyFile = File(
      p.join(
        remote.path,
        kSrsSync2Namespace,
        kProfile,
        'a#1',
        kSrsMediaFolder,
        'old.png',
      ),
    )..createSync(recursive: true);
    legacyFile.writeAsBytesSync(<int>[7, 7]);
    final SrsLocationStore loc = SrsAssetLocationStore(
      store: backend,
      profileUid: kProfile,
    );
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    await addNote(a, '古', '<img src="old.png">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);

    final Directory mediaB = mediaDir('b');
    expect((await media(b, loc, mediaB)).missing, <String>{
      'old.png',
    }, reason: '媒体对账本身不读写入者目录');
    final SrsV1Writers writers = SrsAssetV1Writers(backend, kProfile);
    final Directory writerDir = Directory(
      p.join(remote.path, kSrsSync2Namespace, kProfile, 'a#1'),
    );
    final SrsLocationPrepared prepared = await srsPrepareLocation(
      host: b,
      v1: SrsAssetLocationStore(
        store: backend,
        profileUid: kProfile,
        folder: kSrsSync2V1Folder,
      ),
      current: loc,
      locationId: 'remote',
      key: null,
      nowMs: () => b.now().$1,
      recordPresence: true,
      writers: writers,
    );
    expect(prepared.error, isNull);
    expect(prepared.bound, 1);
    expect(
      await loc.get(srsMediaContentPath(kSrsMediaFolder, sha(<int>[7, 7]))),
      <int>[7, 7],
    );
    expect(prepared.deferredWriters.keys, <(String, String)>[
      ('a#1', 'old.png'),
    ]);
    expect(legacyFile.existsSync(), isTrue, reason: '绑定还没发布到位置：旧文件留着');
    // 收尾之前写入者目录里又来了一个（列表之后才出现的）文件：收尾只删逐个确认搬好的那个。
    final File lateFile = File(
      p.join(writerDir.path, kSrsMediaFolder, 'late.png'),
    )..writeAsBytesSync(<int>[8]);
    expect(await srsSyncOnce(b, loc), isA<SrsSync2Report>());
    expect(
      await srsFinishLocationMigration(
        host: b,
        v1: SrsAssetLocationStore(
          store: backend,
          profileUid: kProfile,
          folder: kSrsSync2V1Folder,
        ),
        prepared: prepared,
        progressId: 'test',
        writers: writers,
      ),
      1,
    );
    expect(legacyFile.existsSync(), isFalse, reason: '绑定发布后删');
    expect(lateFile.readAsBytesSync(), <int>[8], reason: '不整目录删');
    final SrsMediaSyncReport r = await media(b, loc, mediaB);
    expect(r.downloaded, 1);
    expect(File(p.join(mediaB.path, 'old.png')).readAsBytesSync(), <int>[7, 7]);
    // B 补上的绑定随同步到第三台，它直接从内容目录拿。
    await srsSyncOnce(b, loc);
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    expect((await media(c, loc, mediaDir('c'))).downloaded, 1);
  });

  test('BUG-3865：媒体对账不在调用方 isolate 上逐个同步 stat 本机文件', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final Directory mediaA = mediaDir('a');
    final SrsDbStore a = await device('a');
    // 两边都有的一大批 + 只在本机的一个（该上传）+ 只在位置上的一个（该下载）。
    const int both = 300;
    final StringBuffer pictures = StringBuffer();
    for (int i = 0; i < both; i++) {
      final String name = 'shared$i.png';
      writeMedia(mediaA, name, <int>[i % 256]);
      loc.files[at(<int>[i % 256])] = Uint8List.fromList(<int>[i % 256]);
      pictures.write('<img src="$name">');
    }
    writeMedia(mediaA, 'localonly.png', <int>[1, 1]);
    // 别的设备传上去并绑定了的：按绑定从内容目录下载。
    loc.files[at(<int>[2, 2])] = Uint8List.fromList(<int>[2, 2]);
    pictures.write('<img src="localonly.png"><img src="remoteonly.png">');
    await addNote(a, '多', pictures.toString());
    await a.sync2Command(<String, Object?>{
      'op': 'media_bind_unbound',
      'items': <Map<String, Object?>>[
        <String, Object?>{
          'name': 'remoteonly.png',
          'sha': sha(<int>[2, 2]),
          'size': 2,
        },
      ],
      'now': a.now().$1,
    });

    final List<String> syncStats = <String>[];
    final SrsMediaSyncReport r = await IOOverrides.runZoned(
      () => media(a, loc, mediaA),
      createFile: (String path) => _StatSpyFile(path, syncStats),
    );
    expect(syncStats, isEmpty, reason: '同步 stat 会把整轮对账钉在 UI isolate 的微任务里');
    expect(r.uploaded, 1);
    expect(r.downloaded, 1);
    expect(r.missing, isEmpty);
    expect(File(p.join(mediaA.path, 'remoteonly.png')).readAsBytesSync(), <int>[
      2,
      2,
    ]);
    expect(await loc.get(at(<int>[1, 1])), <int>[1, 1]);
    expect(await loc.get(at(<int>[2, 2])), <int>[2, 2]);
  });

  // 同步收尾 UI 卡一两秒：两边都有的媒体没有任何真正挂起的 IO，逐个走一遍异步流程就是一长串微任务、整段不回
  // 事件循环。它们必须在进并发池之前被同步筛掉——一轮对账的微任务数不随这类名字的数量增长。
  test('两边都有的媒体不进逐个异步流程：微任务数与它们的数量无关', () async {
    Future<int> microtasksWith(int both) async {
      final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
      final Directory dir = mediaDir('both$both');
      final SrsDbStore s = await device('m$both');
      final StringBuffer pictures = StringBuffer();
      for (int i = 0; i < both; i++) {
        final String name = 'shared$i.png';
        final List<int> bytes = <int>[i % 256, i ~/ 256];
        writeMedia(dir, name, bytes);
        loc.files[at(bytes)] = Uint8List.fromList(bytes);
        pictures.write('<img src="$name">');
      }
      await addNote(s, '多$both', pictures.toString());
      int scheduled = 0;
      final SrsMediaSyncReport r = await runZoned(
        () => media(s, loc, dir),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask:
              (Zone self, ZoneDelegate parent, Zone zone, void Function() f) {
                scheduled++;
                parent.scheduleMicrotask(zone, f);
              },
        ),
      );
      expect(r.uploaded, 0);
      expect(r.downloaded, 0);
      expect(r.completed, isTrue);
      return scheduled;
    }

    // 内容目录按 256 个前缀分子目录：两边的数都大到前缀目录基本占满，列目录的开销就与名字数无关。
    final int few = await microtasksWith(600);
    final int many = await microtasksWith(2000);
    expect(
      many - few,
      lessThan(200),
      reason: '多出 1400 个两边都有的名字多出了 ${many - few} 个微任务（$few → $many）',
    );
  });

  // 审查 S-3：以前按名字存 `media/<名字>`，两台设备各有一个同名不同内容的 image.jpg 时各留各的、永远分叉。
  test('同名不同内容的媒体：两台设备收敛到同一份，两份内容都留在位置上', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    await addNote(a, '画', '<img src="image.jpg">');
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    writeMedia(mediaA, 'image.jpg', <int>[1, 1, 1]);
    writeMedia(mediaB, 'image.jpg', <int>[2, 2]);
    await media(a, loc, mediaA);
    await media(b, loc, mediaB);
    for (int i = 0; i < 2; i++) {
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      await media(a, loc, mediaA);
      await media(b, loc, mediaB);
    }
    final List<int> onA = File(
      p.join(mediaA.path, 'image.jpg'),
    ).readAsBytesSync();
    expect(File(p.join(mediaB.path, 'image.jpg')).readAsBytesSync(), onA);
    expect(
      remoteMedia(loc),
      containsAll(<String>[
        sha(<int>[1, 1, 1]),
        sha(<int>[2, 2]),
      ]),
      reason: '输掉的那份内容在被换掉之前已传上去，不会只此一份地丢掉',
    );
    // 收敛之后：谁都不再下载、不再改绑定。
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    expect((await media(a, loc, mediaA)).downloaded, 0);
    expect((await media(b, loc, mediaB)).downloaded, 0);
  });

  // 集成审查【中】：以前读者校验失败就删位置上的内容对象。读者分不清是对象真坏了还是这次传输坏了（截断的响应、
  // 网盘占位 / 同步中的半截文件），删了可能就删掉了唯一的一份。现在读者只记可疑、不落地、不删；持有原文（本机
  // 哈希对得上）的设备覆盖重传修复。
  test(
    '位置上的内容被截断 / 改坏：按 sha256 校验拒收、不落地、不删；旧布局里对不上的同样拒收；持有者覆盖重传后照常拿到',
    () async {
      final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final Directory mediaA = mediaDir('a');
      final Directory mediaB = mediaDir('b');
      writeMedia(mediaA, 'cat.png', <int>[1, 2, 3, 4]);
      await addNote(a, '猫', '<img src="cat.png">');
      expect((await media(a, loc, mediaA)).uploaded, 1);
      await srsSyncPeers(<SrsDbStore>[a, b], loc);

      // 云盘覆盖写被打断留下的半截文件；旧的按名字目录里是另一份内容。
      loc.files[at(<int>[1, 2, 3, 4])] = Uint8List.fromList(<int>[1, 2]);
      loc.files['$kSrsMediaFolder/cat.png'] = Uint8List.fromList(<int>[9, 9]);
      final SrsMediaSyncReport r = await media(b, loc, mediaB);
      expect(r.rejected, <String>{'cat.png'});
      expect(r.downloaded, 0);
      expect(r.missing, <String>{'cat.png'});
      expect(File(p.join(mediaB.path, 'cat.png')).existsSync(), isFalse);
      expect(loc.files[at(<int>[1, 2, 3, 4])], <int>[
        1,
        2,
      ], reason: 'a reader never deletes (or rewrites) a content object');
      expect(
        loc.files.containsKey(
          srsMediaSuspectMarkerPath(kSrsMediaFolder, sha(<int>[1, 2, 3, 4])),
        ),
        isTrue,
      );
      // 再读一轮仍对不上：照样不落地、不删，标记只写一次。
      final SrsMediaSyncReport still = await media(b, loc, mediaB);
      expect(still.rejected, <String>{'cat.png'});
      expect(loc.files[at(<int>[1, 2, 3, 4])], <int>[1, 2]);

      // 持有原文的 A：用核对过的原文覆盖那份坏的、删掉标记。
      final SrsMediaSyncReport fix = await media(a, loc, mediaA);
      expect(fix.repaired, 1);
      expect(fix.uploaded, 1);
      expect(loc.files[at(<int>[1, 2, 3, 4])], <int>[1, 2, 3, 4]);
      expect(
        loc.files.keys.where((String k) => k.endsWith(kSrsMediaSuspectSuffix)),
        isEmpty,
      );
      expect(
        (await media(a, loc, mediaA)).uploaded,
        0,
        reason: 'repaired once',
      );
      final SrsMediaSyncReport again = await media(b, loc, mediaB);
      expect(again.downloaded, 1);
      expect(again.rejected, isEmpty);
      expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
        1,
        2,
        3,
        4,
      ]);
    },
  );

  // 覆盖重传走按文件覆盖写（[SrsLocationFileStore.putFile]）：流式、不整份读进内存；文件夹位置先写临时名再改名。
  test('持有者覆盖重传可疑内容：按文件覆盖写（不经内存字节），文件夹位置原子替换、不留临时文件', () async {
    final Directory locRoot = Directory(p.join(root.path, 'loc'))
      ..createSync(recursive: true);
    final _StreamOnlyDirectory loc = _StreamOnlyDirectory(locRoot);
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    final List<int> bytes = List<int>.generate(70000, (int i) => i * 7 & 0xff);
    writeMedia(mediaA, 'cat.png', bytes);
    await addNote(a, '猫', '<img src="cat.png">');
    expect((await media(a, loc, mediaA)).uploaded, 1);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    final File object = File(p.join(locRoot.path, at(bytes)));
    object.writeAsBytesSync(bytes.sublist(0, 100));
    expect((await media(b, loc, mediaB)).rejected, <String>{'cat.png'});
    final SrsMediaSyncReport fix = await media(a, loc, mediaA);
    expect(fix.repaired, 1);
    expect(object.readAsBytesSync(), bytes);
    expect(
      loc.contentPuts,
      isEmpty,
      reason: 'content overwrite streams from a file',
    );
    expect(
      locRoot
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .where(
            (String n) =>
                n.startsWith('.srs2tmp-') || n.endsWith(kSrsMediaSuspectSuffix),
          ),
      isEmpty,
    );
    final SrsMediaSyncReport again = await media(b, loc, mediaB);
    expect(again.downloaded, 1);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), bytes);
  });

  test('文件夹位置 putFile：同名覆盖、中间目录按需建；源文件不动', () async {
    final Directory locRoot = Directory(p.join(root.path, 'loc2'));
    final SrsDirectoryLocationStore loc = SrsDirectoryLocationStore(locRoot);
    final File src = File(p.join(root.path, 'src.bin'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await loc.putFile('x/y/z.bin', src);
    expect(await loc.get('x/y/z.bin'), <int>[1, 2, 3]);
    src.writeAsBytesSync(<int>[4, 5]);
    await loc.putFile('x/y/z.bin', src);
    expect(await loc.get('x/y/z.bin'), <int>[4, 5]);
    expect(src.readAsBytesSync(), <int>[4, 5]);
    expect(
      Directory(
        p.join(locRoot.path, 'x', 'y'),
      ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['z.bin'],
    );
    final SrsMemoryLocationStore mem = SrsMemoryLocationStore();
    await mem.putFile('a/b', src);
    await mem.putFile('a/b', src);
    expect(mem.files['a/b'], <int>[4, 5]);
  });

  // 同上，记日志的位置（给了 locationId，不列目录）：可疑经日志传到持有者，持有者覆盖重传后记回「在」。
  test('记日志的位置：读者把坏内容记为可疑（不删、不落地），可疑随日志传到持有者，持有者覆盖重传修复', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    const String id = 'test';
    writeMedia(mediaA, 'cat.png', <int>[1, 2, 3, 4]);
    await addNote(a, '猫', '<img src="cat.png">');
    expect((await media(a, loc, mediaA, locationId: id)).uploaded, 1);
    await srsSyncPeers(<SrsDbStore>[a, b], loc, locationId: id);

    loc.files[at(<int>[1, 2, 3, 4])] = Uint8List.fromList(<int>[1, 2]);
    final SrsMediaSyncReport r = await media(b, loc, mediaB, locationId: id);
    expect(r.rejected, <String>{'cat.png'});
    expect(r.downloaded, 0);
    expect(File(p.join(mediaB.path, 'cat.png')).existsSync(), isFalse);
    expect(loc.files[at(<int>[1, 2, 3, 4])], <int>[1, 2]);
    expect(
      loc.files.keys.where((String k) => k.endsWith(kSrsMediaSuspectSuffix)),
      isEmpty,
      reason: 'a logged location carries the suspicion in the log, not markers',
    );
    final String key = srsMediaContentPresenceKey(id, kSrsMediaFolder);
    Future<Map<String, Object?>> known(SrsDbStore s) async =>
        (await s.sync2Command(<String, Object?>{
          'op': 'media_known',
          'location': key,
        })).map;
    expect((await known(b))['suspect'], <String>[
      sha(<int>[1, 2, 3, 4]),
    ]);

    // 持有者没收到 B 的日志之前不知道：照常认为在，不重传。
    expect((await media(a, loc, mediaA, locationId: id)).repaired, 0);
    await srsSyncPeers(<SrsDbStore>[b, a], loc, locationId: id);
    expect((await known(a))['suspect'], <String>[
      sha(<int>[1, 2, 3, 4]),
    ]);
    final SrsMediaSyncReport fix = await media(a, loc, mediaA, locationId: id);
    expect(fix.repaired, 1);
    expect(loc.files[at(<int>[1, 2, 3, 4])], <int>[1, 2, 3, 4]);
    expect((await known(a))['suspect'], isEmpty);

    await srsSyncPeers(<SrsDbStore>[a, b], loc, locationId: id);
    final SrsMediaSyncReport again = await media(
      b,
      loc,
      mediaB,
      locationId: id,
    );
    expect(again.downloaded, 1);
    expect(again.rejected, isEmpty);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect((await known(b))['suspect'], isEmpty);
  });

  // 审查 S-10：以前媒体在整轮操作同步之后才传，读到新段的设备一时拿不到它引用的媒体。
  test('一轮同步里媒体先于引用它的段上传；对端收了这一轮就拿得到', () async {
    final _OrderedStore loc = _OrderedStore();
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final Directory mediaA = mediaDir('a');
    final Directory mediaB = mediaDir('b');
    writeMedia(mediaA, 'cat.png', <int>[5, 5]);
    await addNote(a, '猫', '<img src="cat.png">');
    Future<SrsSync2Report> round(SrsDbStore s, Directory dir) => srsSync2Round(
      host: s,
      location: loc,
      locationId: 'loc',
      nowMs: () => s.now().$1,
      beforeUpload: (String? keyHex) async {
        await srsSyncMedia(
          location: loc,
          store: s,
          mediaRoot: dir,
          uploadOnly: true,
        );
      },
    );
    await round(a, mediaA);
    final int mediaAt = loc.order.indexOf(at(<int>[5, 5]));
    final int firstSegment = loc.order.indexWhere(
      (String k) => k.contains('/seg-'),
    );
    expect(mediaAt, isNonNegative);
    expect(firstSegment, greaterThan(mediaAt));
    await round(b, mediaB);
    expect(
      File(p.join(mediaB.path, 'cat.png')).existsSync(),
      isFalse,
      reason: '发段前那一步只上传、不下载',
    );
    final SrsMediaSyncReport rb = await media(b, loc, mediaB);
    expect(rb.downloaded, 1);
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[5, 5]);
  });
}

/// 文件夹位置：内容对象（`media/<2>/<sha256>`）若按内存字节写（[put]）就记下来——覆盖重传应当走 [putFile]。
class _StreamOnlyDirectory extends SrsDirectoryLocationStore {
  _StreamOnlyDirectory(super.root);

  final List<String> contentPuts = <String>[];

  @override
  Future<void> put(String path, Uint8List bytes) {
    if (path.startsWith('$kSrsMediaFolder/') &&
        path.split('/').length == 3 &&
        !path.endsWith(kSrsMediaSuspectSuffix)) {
      contentPuts.add(path);
    }
    return super.put(path, bytes);
  }
}

/// 记下写入顺序的内存位置。
class _OrderedStore extends SrsMemoryLocationStore {
  final List<String> order = <String>[];

  @override
  Future<void> put(String path, Uint8List bytes) {
    order.add(path);
    return super.put(path, bytes);
  }
}

/// 记录同步 stat 类调用（`existsSync` / `statSync` / `lengthSync` / `lastModifiedSync`）的 [File] 代理；
/// 其余成员转给真实文件。用到没转发的成员时直接抛错，免得测试悄悄走了别的路径。
class _StatSpyFile implements File {
  _StatSpyFile(String path, this._log) : _real = _realFile(path);

  final File _real;
  final List<String> _log;

  static File _realFile(String path) =>
      IOOverrides.runWithIOOverrides(() => File(path), _NoOverrides());

  void _record(String what) => _log.add('$what ${_real.path}');

  @override
  String get path => _real.path;
  @override
  Directory get parent => _real.parent;
  @override
  Uri get uri => _real.uri;
  @override
  bool get isAbsolute => _real.isAbsolute;
  @override
  File get absolute => _real.absolute;
  @override
  Future<bool> exists() => _real.exists();
  @override
  bool existsSync() {
    _record('existsSync');
    return _real.existsSync();
  }

  @override
  FileStat statSync() {
    _record('statSync');
    return _real.statSync();
  }

  @override
  int lengthSync() {
    _record('lengthSync');
    return _real.lengthSync();
  }

  @override
  DateTime lastModifiedSync() {
    _record('lastModifiedSync');
    return _real.lastModifiedSync();
  }

  @override
  Future<FileStat> stat() => _real.stat();
  @override
  Future<int> length() => _real.length();
  @override
  Future<Uint8List> readAsBytes() => _real.readAsBytes();
  // 流式读写（审查 S-9：上传前边拷快照边算哈希，不整份读进内存）。
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      _real.openRead(start, end);
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => _real.openWrite(mode: mode, encoding: encoding);
  @override
  Future<File> copy(String newPath) => _real.copy(newPath);
  // 文件流在当前 zone 里按路径重造 File 再 open（即本代理）。
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _real.open(mode: mode);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => _real.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String newPath) => _real.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_StatSpyFile 没转发 ${invocation.memberName}');
}

/// 不覆盖任何东西的 [IOOverrides]：在代理里造真实 [File] 时跳出外层的 `createFile`。
final class _NoOverrides extends IOOverrides {}
