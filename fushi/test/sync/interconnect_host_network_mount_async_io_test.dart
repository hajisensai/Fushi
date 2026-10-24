// BUG-3704：互联 host 跑在 app 主 isolate 上（服务端没有独立 isolate）。视频放在网络盘
// （rclone / SMB / WinFsp 挂载）上时，任何一次同步 stat / exists / length / list 都要等
// 挂载端逐级重列目录，单次 0.15–4.4 s，期间全部端点（含 /api/ping）与 UI 一起冻住。
//
// 本文件起一台真 [FushiSyncServer] + 真 [LocalLibraryHostService]，在 IOOverrides 里把
// 「网络盘」上的路径换成假文件：同步文件 API 一律记账并抛错，async API 照常回话。逐个
// 端点打真 HTTP 请求，钉住：① 网络盘路径零同步文件调用；② 网络盘 stat 还没回话时
// /api/ping 照常秒回（isolate 没被堵住）。
//
// 覆盖：视频清单 / 封面 / streamurl / stream / 外挂字幕 / 内封字幕取轨 / 弹幕指纹 /
// 句子音频裁切 / 清字幕（含 sidecar 备份）/ WebDAV GET·HEAD·PROPFIND·MKCOL·DELETE。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// 假网络盘路径标记（跨平台：只看路径里有没有这一段）。
const String _kNetSegment = '__fushi_net_mount__';

bool _isNetPath(String path) => path.contains(_kNetSegment);

/// 假网络盘：文件内容在内存里；同步 API 记账并抛错；async API 在 [gate] 放闸后回话。
class _FakeNetMount {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Set<String> dirs = <String>{};
  final List<String> syncCalls = <String>[];
  Completer<void> gate = Completer<void>()..complete();
  int asyncCalls = 0;

  String _norm(String path) => p.normalize(path);

  Future<void> _wait() async {
    asyncCalls++;
    await gate.future;
  }

  bool isFile(String path) => files.containsKey(_norm(path));

  bool isDir(String path) {
    final String n = _norm(path);
    if (dirs.contains(n)) return true;
    return files.keys.any((String f) => p.isWithin(n, f)) ||
        dirs.any((String d) => p.isWithin(n, d));
  }

  FileSystemEntityType typeOf(String path) {
    if (isFile(path)) return FileSystemEntityType.file;
    if (isDir(path)) return FileSystemEntityType.directory;
    return FileSystemEntityType.notFound;
  }

  Never sync(String what, String path) {
    syncCalls.add('$what $path');
    throw StateError('sync file IO on network mount: $what $path');
  }
}

class _NetStat implements FileStat {
  _NetStat(this.type, this.size);

  @override
  final FileSystemEntityType type;
  @override
  final int size;
  @override
  DateTime get modified => DateTime.utc(2026, 10, 23);
  @override
  DateTime get changed => modified;
  @override
  DateTime get accessed => modified;
  @override
  int get mode => 0;
  @override
  String modeString() => '---------';
}

class _NetFile implements File {
  _NetFile(String path, this.mount) : path = p.normalize(path);

  @override
  final String path;
  final _FakeNetMount mount;

  @override
  Directory get parent => Directory(p.dirname(path));

  @override
  File get absolute => this;

  @override
  Future<FileStat> stat() async {
    await mount._wait();
    final Uint8List? bytes = mount.files[path];
    return _NetStat(mount.typeOf(path), bytes?.length ?? -1);
  }

  @override
  Future<bool> exists() async {
    await mount._wait();
    return mount.isFile(path);
  }

  @override
  Future<int> length() async {
    await mount._wait();
    final Uint8List? bytes = mount.files[path];
    if (bytes == null) throw FileSystemException('not found', path);
    return bytes.length;
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    await mount._wait();
    final Uint8List? bytes = mount.files[path];
    if (bytes == null) throw FileSystemException('not found', path);
    yield bytes.sublist(start ?? 0, end ?? bytes.length);
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    await mount._wait();
    return encoding.decode(mount.files[path]!);
  }

  @override
  Future<Uint8List> readAsBytes() async {
    await mount._wait();
    final Uint8List? bytes = mount.files[path];
    if (bytes == null) throw FileSystemException('not found', path);
    return bytes;
  }

  @override
  Future<File> rename(String newPath) async {
    await mount._wait();
    final Uint8List? bytes = mount.files.remove(path);
    if (bytes == null) throw FileSystemException('not found', path);
    mount.files[p.normalize(newPath)] = bytes;
    return File(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await mount._wait();
    if (mount.files.remove(path) == null) {
      throw FileSystemException('not found', path);
    }
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      mount.sync('File.${invocation.memberName}', path);
}

class _NetDirectory implements Directory {
  _NetDirectory(String path, this.mount) : path = p.normalize(path);

  @override
  final String path;
  final _FakeNetMount mount;

  @override
  Directory get parent => Directory(p.dirname(path));

  @override
  Directory get absolute => this;

  @override
  Future<bool> exists() async {
    await mount._wait();
    return mount.isDir(path);
  }

  @override
  Future<FileStat> stat() async {
    await mount._wait();
    return _NetStat(mount.typeOf(path), 0);
  }

  @override
  Future<Directory> create({bool recursive = false}) async {
    await mount._wait();
    mount.dirs.add(path);
    return this;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await mount._wait();
    mount.dirs.removeWhere((String d) => d == path || p.isWithin(path, d));
    mount.files.removeWhere((String f, _) => p.isWithin(path, f));
    return this;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    await mount._wait();
    if (!mount.isDir(path)) {
      throw PathNotFoundException(path, const OSError('not found', 2));
    }
    final Set<String> seenDirs = <String>{};
    for (final String f in mount.files.keys.toList()) {
      if (!p.isWithin(path, f)) continue;
      final String first = p.split(p.relative(f, from: path)).first;
      final String child = p.join(path, first);
      if (child == f) {
        yield File(f);
      } else if (seenDirs.add(child)) {
        yield Directory(child);
      }
    }
    for (final String d in mount.dirs.toList()) {
      if (!p.isWithin(path, d)) continue;
      final String child = p.join(
        path,
        p.split(p.relative(d, from: path)).first,
      );
      if (seenDirs.add(child)) yield Directory(child);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      mount.sync('Directory.${invocation.memberName}', path);
}

/// 只认网络盘之外路径的 ffmpeg 替身：探测回「没有内封字幕轨」，裁切 / 抽取都不产出。
/// 网络盘 IO 只在 Dart 侧发生（ffmpeg 子进程读文件不经 isolate），这里不必模拟。
class _NoTracksFfmpeg implements FfmpegBackend {
  final List<List<String>> runs = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs.add(args);
    return FfmpegRunResult(returnCode: 1, output: '');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 在 [mount] 生效的 IOOverrides 里跑 [body]；非网络盘路径交回真实文件系统。
Future<T> _withNetMount<T>(_FakeNetMount mount, Future<T> Function() body) {
  final Zone outer = Zone.current;
  return IOOverrides.runZoned<Future<T>>(
    body,
    createFile: (String path) =>
        _isNetPath(path) ? _NetFile(path, mount) : outer.run(() => File(path)),
    createDirectory: (String path) => _isNetPath(path)
        ? _NetDirectory(path, mount)
        : outer.run(() => Directory(path)),
    fseGetType: (String path, bool followLinks) async {
      if (!_isNetPath(path)) {
        return outer.run(
          () => FileSystemEntity.type(path, followLinks: followLinks),
        );
      }
      await mount._wait();
      return mount.typeOf(path);
    },
    fseGetTypeSync: (String path, bool followLinks) => _isNetPath(path)
        ? mount.sync('FileSystemEntity.typeSync', path)
        : outer.run(
            () => FileSystemEntity.typeSync(path, followLinks: followLinks),
          ),
    fseIdentical: (String a, String b) async =>
        outer.run(() => FileSystemEntity.identical(a, b)),
    fseIdenticalSync: (String a, String b) => _isNetPath(a) || _isNetPath(b)
        ? mount.sync('FileSystemEntity.identicalSync', a)
        : outer.run(() => FileSystemEntity.identicalSync(a, b)),
    statSync: (String path) => _isNetPath(path)
        ? mount.sync('FileStat.statSync', path)
        : outer.run(() => FileStat.statSync(path)),
  );
}

const String _kToken = 'net-mount-token';
const String _kVideoId = 'netvid1';

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late _FakeNetMount mount;
  late _NoTracksFfmpeg ffmpeg;
  late String netRoot;
  late String showDir;
  late String videoPath;
  late String sidecarPath;
  late String coverPath;
  final HttpClient http = HttpClient();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hbk_net_mount_host');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    mount = _FakeNetMount();
    ffmpeg = _NoTracksFfmpeg();
    setFfmpegBackendForTesting(ffmpeg);
    setTranscodeAvailableForTesting(false);
    netRoot = p.join(tmp.path, _kNetSegment);
    showDir = p.join(netRoot, 'show');
    videoPath = p.join(showDir, 'ep1.mkv');
    sidecarPath = p.join(showDir, 'ep1.ja.srt');
    coverPath = p.join(netRoot, 'covers', 'ep1.jpg');
    mount.files[videoPath] = Uint8List.fromList(
      List<int>.generate(4096, (int i) => i & 0xff),
    );
    mount.files[sidecarPath] = Uint8List.fromList(
      utf8.encode('1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n'),
    );
    mount.files[p.join(showDir, 'ep1.en.srt')] = Uint8List.fromList(
      utf8.encode('1\n00:00:00,000 --> 00:00:01,000\nhello\n'),
    );
    mount.files[coverPath] = Uint8List.fromList(<int>[0xff, 0xd8, 0xff]);
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    setTranscodeAvailableForTesting(null);
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  tearDownAll(() => http.close(force: true));

  LocalLibraryHostService makeService() => LocalLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory(p.join(tmp.path, 'dicts'))
      ..createSync(recursive: true),
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    videoSubtitleLangCode: 'ja',
  );

  Future<void> seedVideo() => db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: _kVideoId,
      title: 'EP1',
      videoPath: videoPath,
      coverPath: Value<String?>(coverPath),
      subtitleSource: Value<String?>(sidecarPath),
      subtitleFormat: const Value<String?>('srt'),
    ),
  );

  /// 在网络盘 IOOverrides 里起 host（请求处理跟着 listen 时的 zone 走），返回 base URL。
  Future<(FushiSyncServer, String)> startHost({String? syncDataDir}) async {
    final FushiSyncServer server = await _withNetMount(mount, () async {
      final FushiSyncServer s = FushiSyncServer(
        syncDataDir: syncDataDir ?? p.join(tmp.path, 'srv'),
        port: 0,
        token: _kToken,
        allowLan: false,
        libraryService: makeService(),
      );
      await s.start();
      return s;
    });
    addTearDown(server.stop);
    return (server, 'http://127.0.0.1:${server.port}');
  }

  Future<HttpClientResponse> send(
    String method,
    String url, {
    bool auth = true,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final HttpClientRequest req = await http.openUrl(method, Uri.parse(url));
    if (auth) {
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$_kToken'))}',
      );
    }
    headers.forEach(req.headers.set);
    return req.close();
  }

  Future<(int, String)> fetch(
    String method,
    String url, {
    bool auth = true,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final HttpClientResponse res = await send(
      method,
      url,
      auth: auth,
      headers: headers,
    );
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  test('视频端点全链路：网络盘零同步文件调用，字段与旧语义一致', () async {
    await seedVideo();
    final (_, String base) = await startHost();
    final String v = '$base/api/library/videos/$_kVideoId';

    final (int listCode, String listBody) = await fetch(
      'GET',
      '$base/api/library/videos',
    );
    expect(listCode, 200);
    final Map<String, dynamic> row =
        (jsonDecode(listBody) as List<dynamic>).single as Map<String, dynamic>;
    expect(row['sizeBytes'], 4096);
    expect(row['hasCover'], isTrue);
    expect(row['coverUrl'], contains('/api/library/videos/$_kVideoId/cover'));

    final HttpClientResponse cover = await send('GET', '$v/cover');
    expect(cover.statusCode, 200);
    expect(await cover.fold<int>(0, (int n, List<int> c) => n + c.length), 3);

    final (int urlCode, String urlBody) = await fetch('GET', '$v/streamurl');
    expect(urlCode, 200);
    final Map<String, dynamic> streamUrl =
        jsonDecode(urlBody) as Map<String, dynamic>;
    // 同目录 sidecar 按学习语言（ja）选中（findSidecarSubtitle，async 列目录）。
    expect(streamUrl['subtitleFileName'], 'ep1.ja.srt');

    final HttpClientResponse full = await send(
      'GET',
      streamUrl['url'] as String,
      auth: false,
    );
    expect(full.statusCode, 200);
    final String etag = full.headers.value(HttpHeaders.etagHeader)!;
    expect(etag, startsWith('"vid-4096-'));
    expect(await full.fold<int>(0, (int n, List<int> c) => n + c.length), 4096);

    final HttpClientResponse ranged = await send(
      'GET',
      streamUrl['url'] as String,
      auth: false,
      headers: <String, String>{'range': 'bytes=100-199', 'if-range': etag},
    );
    expect(ranged.statusCode, 206);
    expect(ranged.headers.value('content-range'), 'bytes 100-199/4096');
    await ranged.drain<void>();

    final (int subCode, String subBody) = await fetch('GET', '$v/subtitle');
    expect(subCode, 200);
    expect(subBody, contains('こんにちは'));

    // 内封字幕取轨：替身探不出轨 → 404，但 stat 视频 / 缓存键都走过了。
    final (int embCode, _) = await fetch(
      'GET',
      '$v/subtitle?embeddedStreamIndex=2',
    );
    expect(embCode, 404);

    final (int danmakuCode, String danmakuBody) = await fetch(
      'GET',
      '$v/danmakukey',
    );
    expect(danmakuCode, 200);
    final Map<String, dynamic> key =
        jsonDecode(danmakuBody) as Map<String, dynamic>;
    expect(key['fileSize'], 4096);
    expect(key['fileName'], 'ep1');

    // 句子音频裁切：替身 ffmpeg 不产出 → 404，但输入存在性判据已走过网络盘。
    final (int clipCode, _) = await fetch(
      'GET',
      '$v/clipaudio?startMs=0&endMs=1000',
    );
    expect(clipCode, 404);
    expect(
      ffmpeg.runs.any((List<String> a) => a.contains(videoPath)),
      isTrue,
      reason: '裁切应已越过输入存在性判据、真正调起 ffmpeg',
    );

    expect(
      mount.syncCalls,
      isEmpty,
      reason: 'host 端点对网络盘路径不得有任何同步文件调用（BUG-3704）',
    );
    expect(mount.asyncCalls, greaterThan(0));
  });

  test('清字幕（含全部 sidecar 备份）对网络盘零同步文件调用', () async {
    await seedVideo();
    final (_, String base) = await startHost();

    final (int code, String body) = await fetch(
      'DELETE',
      '$base/api/library/videos/$_kVideoId/subtitle?which=primary&sidecars=all',
    );
    expect(code, 200, reason: body);
    final Map<String, dynamic> result =
        jsonDecode(body) as Map<String, dynamic>;
    final Map<String, dynamic> backedUp =
        result['backedUpFiles'] as Map<String, dynamic>;
    expect(backedUp.keys, containsAll(<String>[sidecarPath]));
    expect(mount.files.containsKey(sidecarPath), isFalse);
    expect(mount.files.containsKey('$sidecarPath.fushi-bak'), isTrue);
    expect(result['remainingSidecars'], isEmpty);
    expect(mount.syncCalls, isEmpty);
  });

  test('网络盘 stat 还没回话时 /api/ping 照常秒回（isolate 没被堵住）', () async {
    await seedVideo();
    final (_, String base) = await startHost();
    final (int urlCode, String urlBody) = await fetch(
      'GET',
      '$base/api/library/videos/$_kVideoId/streamurl',
    );
    expect(urlCode, 200);
    final String streamUrl =
        (jsonDecode(urlBody) as Map<String, dynamic>)['url'] as String;

    mount.gate = Completer<void>();
    final int before = mount.asyncCalls;
    final Future<HttpClientResponse> pending = send(
      'GET',
      streamUrl,
      auth: false,
    );
    // 等 host 真的卡在网络盘 IO 上。
    final Stopwatch waitIo = Stopwatch()..start();
    while (mount.asyncCalls == before) {
      expect(waitIo.elapsed, lessThan(const Duration(seconds: 10)));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final Stopwatch ping = Stopwatch()..start();
    final (int pingCode, _) = await fetch('GET', '$base/api/ping', auth: false);
    ping.stop();
    expect(pingCode, 200);
    expect(ping.elapsed, lessThan(const Duration(seconds: 2)));

    mount.gate.complete();
    final HttpClientResponse res = await pending;
    expect(res.statusCode, 200);
    await res.drain<void>();
    expect(mount.syncCalls, isEmpty);
  });

  test(
    'WebDAV 同步根在网络盘上：GET / HEAD / PROPFIND / MKCOL / DELETE 零同步调用',
    () async {
      final String root = p.join(netRoot, 'webdav');
      final (FushiSyncServer server, String base) = await startHost(
        syncDataDir: root,
      );
      final String dataDir = server.syncDataDir;
      mount.files[p.join(dataDir, 'book', 'a.json')] = Uint8List.fromList(
        utf8.encode('{"a":1}'),
      );

      final (int getCode, String getBody) = await fetch(
        'GET',
        '$base/book/a.json',
      );
      expect(getCode, 200);
      expect(getBody, '{"a":1}');

      // HEAD 只钉状态码：Content-Length 头由 shelf_io / dart:io 对 HEAD 的处理决定，与本修复无关。
      final HttpClientResponse head = await send('HEAD', '$base/book/a.json');
      expect(head.statusCode, 200);
      await head.drain<void>();

      final (int missingCode, _) = await fetch(
        'GET',
        '$base/book/missing.json',
      );
      expect(missingCode, 404);

      final (int propCode, String propBody) = await fetch(
        'PROPFIND',
        '$base/book/',
        headers: <String, String>{'depth': '1'},
      );
      expect(propCode, 207);
      expect(propBody, contains('a.json'));

      final (int mkcolCode, _) = await fetch('MKCOL', '$base/newdir');
      expect(mkcolCode, 201);
      final (int mkcolAgain, _) = await fetch('MKCOL', '$base/newdir');
      expect(mkcolAgain, 405);

      final (int delCode, _) = await fetch('DELETE', '$base/book/a.json');
      expect(delCode, 204);
      expect(
        mount.files.containsKey(p.join(dataDir, 'book', 'a.json')),
        isFalse,
      );

      expect(mount.syncCalls, isEmpty);
    },
  );
}
