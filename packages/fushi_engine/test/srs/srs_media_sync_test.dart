// SRS 媒体同步（srs_media_sync.dart，docs/specs/2026-10-25-srs-sync-v2-design.md §6.4、§10.5）：集合根下一个
// 内容寻址的 `media/` 目录；缺的从位置下载、位置缺的上传；被删笔记的媒体保留 90 天后才从位置上清，删除只凭
// 正面证据（本机不认识的文件不删）；归档位置永不删；旧格式按写入者分目录的媒体只读兜底。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
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
        monotonicMs: () => t,
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
    SrsLegacyMediaReader? legacy,
  }) => srsSyncMedia(
    location: loc,
    store: s,
    mediaRoot: dir,
    archive: archive,
    legacy: legacy,
  );

  Set<String> remoteMedia(SrsMemoryLocationStore loc) => <String>{
    for (final String path in loc.files.keys)
      if (path.startsWith('$kSrsMediaFolder/'))
        path.substring(kSrsMediaFolder.length + 1),
  };

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
    expect(remoteMedia(loc), <String>{'cat.png', 'meow.mp3'});
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
    loc.files.remove('$kSrsMediaFolder/cat.png');
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
    await loc.put(
      '$kSrsMediaFolder/stranger.png',
      Uint8List.fromList(<int>[9]),
    );

    t += 1000;
    await a.deleteNote(gone);
    await srsSyncPeers(<SrsDbStore>[a, b], loc);
    t += 89 * kDay;
    SrsMediaSyncReport r = await media(a, loc, mediaA);
    expect(r.deleted, 0, reason: '保留期内不删');
    expect(remoteMedia(loc), contains('only.png'));
    // 保留期内恢复笔记媒体还在：新设备照样下载被删笔记的媒体。
    final SrsDbStore c = await device('c');
    await srsSyncOnce(c, loc);
    final Directory mediaC = mediaDir('c');
    expect((await media(c, loc, mediaC)).downloaded, 2);
    expect(File(p.join(mediaC.path, 'only.png')).existsSync(), isTrue);

    t += 2 * kDay;
    r = await media(a, loc, mediaA);
    expect(r.deleted, 1);
    expect(remoteMedia(loc), <String>{'shared.png', 'stranger.png'});
    expect(
      (await media(b, loc, mediaDir('b'))).uploaded,
      0,
      reason: '看得到删除的设备不会把过期的文件再传上来',
    );
    expect(remoteMedia(loc), isNot(contains('only.png')));
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
    expect(remoteMedia(loc), <String>{'only.png'});
    // 同一份过期状态对普通同步 / 媒体位置就会清。
    expect((await media(a, loc, mediaA)).deleted, 1);
  });

  test('旧格式（按写入者分目录）的媒体只读兜底：下载到本机并补传进 v2 目录，旧目录不动', () async {
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
    }, reason: '没给兜底就只是缺失');
    final SrsMediaSyncReport r = await media(
      b,
      loc,
      mediaB,
      legacy: srsLegacyMediaReader(backend, kProfile),
    );
    expect(r.downloaded, 1);
    expect(r.uploaded, 1);
    expect(File(p.join(mediaB.path, 'old.png')).readAsBytesSync(), <int>[7, 7]);
    expect(await loc.get('$kSrsMediaFolder/old.png'), <int>[7, 7]);
    expect(legacyFile.existsSync(), isTrue, reason: '旧目录不自动删');
    // 之后不需要兜底：第三台直接从 v2 目录拿。
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
      loc.files['$kSrsMediaFolder/$name'] = Uint8List.fromList(<int>[i % 256]);
      pictures.write('<img src="$name">');
    }
    writeMedia(mediaA, 'localonly.png', <int>[1]);
    loc.files['$kSrsMediaFolder/remoteonly.png'] = Uint8List.fromList(<int>[2]);
    pictures.write('<img src="localonly.png"><img src="remoteonly.png">');
    await addNote(a, '多', pictures.toString());

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
    ]);
    expect(await loc.get('$kSrsMediaFolder/localonly.png'), <int>[1]);
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
        writeMedia(dir, name, <int>[i % 256]);
        loc.files['$kSrsMediaFolder/$name'] = Uint8List.fromList(<int>[
          i % 256,
        ]);
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

    final int few = await microtasksWith(20);
    final int many = await microtasksWith(1000);
    expect(
      many - few,
      lessThan(200),
      reason: '980 个两边都有的名字多出了 ${many - few} 个微任务（$few → $many）',
    );
  });
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
