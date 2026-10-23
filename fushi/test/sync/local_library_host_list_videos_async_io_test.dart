// BUG-3663：互联 host 的 `/api/library/videos` 跑在 app 主 isolate 上。旧实现逐行
// `existsSync` / `lengthSync` / `listSync` 视频文件——视频放在网络盘（rclone / SMB /
// WinFsp 挂载）上、挂载端目录缓存过期时，一次同步 stat 要逐级重列目录、单次数秒，
// 整条主 isolate（全部互联端点含 /api/ping、UI）随之冻结 4–16.7 s。
//
// 这里用 IOOverrides 把「网络盘」上的路径换成假文件：任何同步文件 API 都记一笔，
// async API 由测试放闸。钉住两件事：① listVideos 对网络盘路径零同步文件调用；
// ② 文件系统还没回话时 isolate 照常处理别的事件（listVideos 只是在等）。

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// 假网络盘路径标记（跨平台：只看路径里有没有这一段）。
const String _kNetSegment = '__fushi_net_mount__';

bool _isNetPath(String path) => path.contains(_kNetSegment);

/// 假网络盘：同步 API 一律记账并抛错；async API 等 [gate] 放闸后回话。
class _FakeNetMount {
  _FakeNetMount(this.files);

  /// 网络盘上存在的文件：路径 → 字节数。
  final Map<String, int> files;
  final List<String> syncCalls = <String>[];
  final Completer<void> gate = Completer<void>();
  int statCalls = 0;
  int listCalls = 0;
}

class _NetFile implements File {
  _NetFile(this.path, this.mount);

  @override
  final String path;
  final _FakeNetMount mount;

  @override
  Future<FileStat> stat() async {
    mount.statCalls++;
    await mount.gate.future;
    final int? size = mount.files[path];
    return _NetStat(
      size == null ? FileSystemEntityType.notFound : FileSystemEntityType.file,
      size ?? -1,
    );
  }

  @override
  Future<bool> exists() async {
    await mount.gate.future;
    return mount.files.containsKey(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    mount.syncCalls.add('File.${invocation.memberName} $path');
    throw StateError('unexpected File.${invocation.memberName} on $path');
  }
}

class _NetDirectory implements Directory {
  _NetDirectory(this.path, this.mount);

  @override
  final String path;
  final _FakeNetMount mount;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    mount.listCalls++;
    await mount.gate.future;
    for (final String f in mount.files.keys) {
      if (p.dirname(f) == path) yield _NetFile(f, mount);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    mount.syncCalls.add('Directory.${invocation.memberName} $path');
    throw StateError('unexpected Directory.${invocation.memberName} on $path');
  }
}

class _NetStat implements FileStat {
  _NetStat(this.type, this.size);

  @override
  final FileSystemEntityType type;
  @override
  final int size;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  );
}

void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hbk_list_videos_async_io');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  LocalLibraryHostService makeService() => LocalLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory(p.join(tmp.path, 'dicts'))
      ..createSync(recursive: true),
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    videoSubtitleLangCode: 'ja',
  );

  test('网络盘上的视频：listVideos 零同步文件调用，等 stat 时 isolate 照常跑别的事', () async {
    final String showDir = p.join(tmp.path, _kNetSegment, 'show');
    final String ep1 = p.join(showDir, 'ep1.mkv');
    final String ep2 = p.join(showDir, 'ep2.mkv');
    final String cover = p.join(tmp.path, _kNetSegment, 'covers', 'ep1.jpg');
    final _FakeNetMount mount = _FakeNetMount(<String, int>{
      ep1: 1111,
      ep2: 2222,
      p.join(showDir, 'ep1.ja.srt'): 10,
      cover: 5,
    });
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/ep1',
        title: 'EP1',
        videoPath: ep1,
        coverPath: Value<String?>(cover),
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/ep2',
        title: 'EP2',
        videoPath: ep2,
      ),
    );
    // 网络盘上已经不在的文件：stat 回 notFound → sizeBytes null。
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/gone',
        title: 'Gone',
        videoPath: p.join(showDir, 'gone.mkv'),
      ),
    );
    final LocalLibraryHostService svc = makeService();

    final List<RemoteVideoInfo> list = await _withNetMount(mount, () async {
      final Future<List<RemoteVideoInfo>> pending = svc.listVideos();
      // 文件系统还没回话：别的定时器 / 请求必须照常被处理（旧实现同步 stat 时
      // 整条 isolate 卡住，这里根本走不到）。
      bool otherWorkRan = false;
      await Future<void>.delayed(const Duration(milliseconds: 50), () {
        otherWorkRan = true;
      });
      expect(otherWorkRan, isTrue);
      expect(
        mount.statCalls,
        greaterThan(0),
        reason: 'listVideos 应已发出 async stat 并在等它',
      );
      mount.gate.complete();
      return pending;
    });

    expect(mount.syncCalls, isEmpty, reason: 'listVideos 对网络盘路径不得有任何同步文件调用');
    // 同目录只列一次（并发行共用一次列举）。
    expect(mount.listCalls, 1);
    final Map<String, RemoteVideoInfo> byId = <String, RemoteVideoInfo>{
      for (final RemoteVideoInfo v in list) v.id: v,
    };
    expect(byId['video/ep1']!.sizeBytes, 1111);
    expect(byId['video/ep1']!.fileName, 'ep1.mkv');
    expect(byId['video/ep1']!.hasSubtitle, isTrue);
    expect(byId['video/ep1']!.subtitleFileName, 'ep1.ja.srt');
    expect(byId['video/ep1']!.hasCover, isTrue);
    expect(byId['video/ep2']!.sizeBytes, 2222);
    expect(byId['video/ep2']!.hasSubtitle, isFalse);
    expect(byId['video/ep2']!.hasCover, isFalse);
    expect(byId['video/gone']!.sizeBytes, isNull);
    expect(byId['video/gone']!.fileName, isNull);
  });

  test('封面端点 videoCoverPath 同样不对网络盘做同步 stat', () async {
    final String cover = p.join(tmp.path, _kNetSegment, 'covers', 'c.jpg');
    final _FakeNetMount mount = _FakeNetMount(<String, int>{cover: 5});
    mount.gate.complete();
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/c',
        title: 'C',
        videoPath: p.join(tmp.path, 'local.mkv'),
        coverPath: Value<String?>(cover),
      ),
    );
    final LocalLibraryHostService svc = makeService();

    final String? got = await _withNetMount(
      mount,
      () => svc.videoCoverPath('video/c'),
    );

    expect(got, cover);
    expect(mount.syncCalls, isEmpty);
  });
}
