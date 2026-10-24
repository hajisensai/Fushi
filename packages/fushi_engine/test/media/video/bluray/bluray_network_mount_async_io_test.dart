// BUG-3756：互联 host 与 UI 同在 app 主 isolate 上，用户的蓝光盘目录常放在网络盘
// （rclone / SMB / WinFsp 挂载）上，挂载端目录缓存过期后一次同步 stat 要数秒——主
// isolate 上任何一次对盘目录的 `existsSync` / `listSync` / `statSync` 都会冻住全部
// 互联端点与 UI。
//
// 这里用 IOOverrides 把「网络盘」上的路径换成假文件系统：任何同步文件 API 都记一笔
// 并抛错，async API 由测试放闸。钉住两件事：① 认盘 / 读盘 / 解析可播源 / 探规格 /
// 特典划分整条蓝光 IO 链对网络盘零同步文件调用；② 网络盘还没回话时 isolate 照常
// 处理别的事件（读盘只是在等）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc_extras.dart';
import 'package:fushi_engine/media/video/bluray/bluray_probe.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bluray_fixture.dart';

/// 假网络盘路径标记（跨平台：只看路径里有没有这一段）。
const String _kNetSegment = '__fushi_net_mount__';

bool _isNetPath(String path) => path.contains(_kNetSegment);

/// 假网络盘：同步 API 一律记账并抛错；async API 等 [gate] 放闸后回话。
class _FakeNetMount {
  _FakeNetMount(this.files)
    : directories = <String>{
        for (final String file in files.keys) ..._ancestors(file),
      };

  /// 网络盘上存在的文件：路径 → 内容。
  final Map<String, Uint8List> files;

  /// 由 [files] 推出的全部目录（含网络盘根以上的祖先，判据只看路径）。
  final Set<String> directories;

  final List<String> syncCalls = <String>[];
  final Completer<void> gate = Completer<void>();
  int asyncCalls = 0;

  static Iterable<String> _ancestors(String file) sync* {
    String dir = p.dirname(file);
    while (true) {
      yield dir;
      final String parent = p.dirname(dir);
      if (parent == dir) return;
      dir = parent;
    }
  }

  Future<void> _wait() async {
    asyncCalls++;
    await gate.future;
  }

  FileSystemEntityType typeOf(String path) {
    final String normalized = p.normalize(path);
    if (files.containsKey(normalized)) return FileSystemEntityType.file;
    if (directories.contains(normalized)) {
      return FileSystemEntityType.directory;
    }
    return FileSystemEntityType.notFound;
  }

  Never recordSync(String what) {
    syncCalls.add(what);
    throw StateError('unexpected sync file call: $what');
  }
}

class _NetFile implements File {
  _NetFile(this.path, this.mount);

  @override
  final String path;
  final _FakeNetMount mount;

  Uint8List _bytes() {
    final Uint8List? bytes = mount.files[p.normalize(path)];
    if (bytes == null) {
      throw PathNotFoundException(path, const OSError('not found', 2));
    }
    return bytes;
  }

  @override
  Future<bool> exists() async {
    await mount._wait();
    return mount.files.containsKey(p.normalize(path));
  }

  @override
  Future<int> length() async {
    await mount._wait();
    return _bytes().length;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    await mount._wait();
    return _bytes();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    await mount._wait();
    return encoding.decode(_bytes());
  }

  @override
  Future<FileStat> stat() async {
    await mount._wait();
    return _NetStat(mount.typeOf(path), mount.files[p.normalize(path)]?.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      mount.recordSync('File.${invocation.memberName} $path');
}

class _NetDirectory implements Directory {
  _NetDirectory(this.path, this.mount);

  @override
  final String path;
  final _FakeNetMount mount;

  @override
  Future<bool> exists() async {
    await mount._wait();
    return mount.directories.contains(p.normalize(path));
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    await mount._wait();
    final String self = p.normalize(path);
    if (!mount.directories.contains(self)) {
      throw PathNotFoundException(path, const OSError('not found', 2));
    }
    for (final String dir in mount.directories) {
      if (p.dirname(dir) == self && dir != self) {
        yield _NetDirectory(dir, mount);
      }
    }
    for (final String file in mount.files.keys) {
      if (p.dirname(file) == self) yield _NetFile(file, mount);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      mount.recordSync('Directory.${invocation.memberName} $path');
}

class _NetStat implements FileStat {
  _NetStat(this.type, int? size) : size = size ?? -1;

  @override
  final FileSystemEntityType type;
  @override
  final int size;
  @override
  DateTime get modified => DateTime.utc(2026, 10, 23);

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
    fseGetType: (String path, bool followLinks) async {
      if (!_isNetPath(path)) {
        return outer.run(
          () => FileSystemEntity.type(path, followLinks: followLinks),
        );
      }
      await mount._wait();
      return mount.typeOf(path);
    },
    fseGetTypeSync: (String path, bool followLinks) {
      if (!_isNetPath(path)) {
        return outer.run(
          () => FileSystemEntity.typeSync(path, followLinks: followLinks),
        );
      }
      return mount.recordSync('FileSystemEntity.typeSync $path');
    },
    stat: (String path) async {
      if (!_isNetPath(path)) return outer.run(() => FileStat.stat(path));
      await mount._wait();
      return _NetStat(
        mount.typeOf(path),
        mount.files[p.normalize(path)]?.length,
      );
    },
    statSync: (String path) {
      if (!_isNetPath(path)) return outer.run(() => FileStat.statSync(path));
      return mount.recordSync('FileStat.statSync $path');
    },
  );
}

void main() {
  final String root = p.join(
    Directory.systemTemp.path,
    _kNetSegment,
    'Movie [BDMV]',
  );
  final String mainPlaylist = p.join(root, 'BDMV', 'PLAYLIST', '00001.mpls');
  final String mainStream = p.join(root, 'BDMV', 'STREAM', '00001.m2ts');

  /// 一条把整段片段从头用到尾的播放列表 + 配套 CLPI + 码流。
  Map<String, Uint8List> wholeClipTitle(
    String playlistId, {
    required String clipId,
    required int seconds,
  }) {
    const int startTicks = 45000 * 4;
    final int endTicks = startTicks + 45000 * seconds;
    return <String, Uint8List>{
      p.join(root, 'BDMV', 'PLAYLIST', '$playlistId.mpls'): buildMplsFixture(
        playItems: <FixturePlayItem>[
          FixturePlayItem(
            clipId: clipId,
            inTimeTicks: startTicks,
            outTimeTicks: endTicks,
          ),
        ],
        marks: const <FixtureMark>[
          FixtureMark(playItemIndex: 0, timestampTicks: startTicks),
        ],
      ),
      p.join(root, 'BDMV', 'CLIPINF', '$clipId.clpi'): buildClpiFixture(
        presentationStartTicks: startTicks,
        presentationEndTicks: endTicks,
      ),
      p.join(root, 'BDMV', 'STREAM', '$clipId.m2ts'): Uint8List(4096),
    };
  }

  _FakeNetMount makeMount({bool open = true}) {
    final _FakeNetMount mount = _FakeNetMount(<String, Uint8List>{
      ...wholeClipTitle('00001', clipId: '00001', seconds: 7200), // 正片
      ...wholeClipTitle('00002', clipId: '00002', seconds: 600), // 制作特辑
      ...wholeClipTitle('00800', clipId: '00800', seconds: 20), // 菜单循环
      p.join(root, 'BDMV', 'META', 'DL', 'bdmt_jpn.xml'): Uint8List.fromList(
        utf8.encode(
          '<di:discinfo><di:title><di:name>测试盘</di:name></di:title>'
          '</di:discinfo>',
        ),
      ),
    });
    if (open) mount.gate.complete();
    return mount;
  }

  setUp(debugClearBlurayDiscExtrasCache);

  test('认盘：盘根与 BDMV 目录本身都认，别的目录不认；零同步文件调用', () async {
    final _FakeNetMount mount = makeMount();
    final List<String?> roots = await _withNetMount(
      mount,
      () async => <String?>[
        await blurayDiscRootForDirectory(root),
        await blurayDiscRootForDirectory(p.join(root, 'BDMV')),
        await blurayDiscRootForDirectory(p.join(root, 'BDMV', 'STREAM')),
        await blurayDiscRootForDirectory(p.dirname(root)),
      ],
    );
    expect(roots, <String?>[root, root, null, null]);
    expect(mount.syncCalls, isEmpty);
    expect(mount.asyncCalls, greaterThan(0));
  });

  test('读盘 / 解析可播源 / 探规格 / 特典划分：网络盘零同步文件调用', () async {
    final _FakeNetMount mount = makeMount();
    final (
      BlurayDisc? disc,
      BluraySource? source,
      VideoProbeFacts facts,
      Map<String, String> extras,
    ) = await _withNetMount(
      mount,
      () async => (
        await readBlurayDisc(root),
        await resolveBluraySource(mainPlaylist),
        await probeBlurayPlaylistFacts(mainPlaylist),
        await blurayDiscExtras(<String>[
          mainPlaylist,
          p.join(root, 'BDMV', 'PLAYLIST', '00002.mpls'),
        ]),
      ),
    );

    expect(mount.syncCalls, isEmpty);
    expect(disc, isNotNull);
    expect(disc!.name, '测试盘'); // META 读到了
    expect(disc.playlists, hasLength(3));
    expect(disc.titles.map((BlurayTitle t) => t.playlist.id), <String>[
      '00001',
    ]);
    expect(source, isNotNull);
    expect(source!.uri, mainStream); // 单段整段覆盖：直接给码流路径
    expect(facts.isUnavailable, isFalse);
    expect(facts.fileSizeBytes, 4096); // STREAM 体积经 async stat 求和
    // 特典划分跑完了整条链（含指纹 stat）；它的结论另有纯函数测试钉。
    expect(extras, isA<Map<String, String>>());
  });

  test('读盘第二遍走特典缓存：指纹 stat 同样零同步调用', () async {
    final _FakeNetMount mount = makeMount();
    final List<String> paths = <String>[
      mainPlaylist,
      p.join(root, 'BDMV', 'PLAYLIST', '00002.mpls'),
    ];
    final Map<String, String> first = await _withNetMount(
      mount,
      () => blurayDiscExtras(paths),
    );
    final Map<String, String> second = await _withNetMount(
      mount,
      () => blurayDiscExtras(paths),
    );
    expect(second, first);
    expect(mount.syncCalls, isEmpty);
  });

  test('网络盘还没回话时 isolate 照常跑别的定时器（读盘只是在等）', () async {
    final _FakeNetMount mount = makeMount(open: false);
    bool timerFired = false;
    bool done = false;
    final Future<BlurayDisc?> pending = _withNetMount(
      mount,
      () => readBlurayDisc(root),
    ).whenComplete(() => done = true);

    Timer(Duration.zero, () => timerFired = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(timerFired, isTrue);
    expect(done, isFalse);
    expect(mount.asyncCalls, greaterThan(0));

    mount.gate.complete();
    final BlurayDisc? disc = await pending;
    expect(disc, isNotNull);
    expect(mount.syncCalls, isEmpty);
  });
}
