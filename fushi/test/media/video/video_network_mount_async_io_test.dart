// BUG-3704：视频 / 视频旁 sidecar / 封面常落在网络盘（rclone / SMB / WinFsp 挂载）上，
// 挂载端目录缓存过期时一次同步 stat / list 要逐级重列目录、单次 0.15–4.4 s。app 主
// isolate 上只要有一次这样的同步文件调用，UI 与同 isolate 的互联 host 端点就一起冻结。
//
// 这里用 IOOverrides 造一块「网络盘」：同步文件 API 一律记账并抛错，async API 等测试
// 放闸后才回话。钉住播放 / 补字幕 / 封面回填这几条打开视频时必经的 fushi/lib 路径：
//  - 弹幕 sidecar 查找与读取（打开视频即触发）；
//  - 封面回填失败账本（视频库页进页即对整库跑）；
//  - 自动补字幕的 sidecar 判据（下载落盘前的存在检查）。
// 对网络盘路径零同步调用，且等网络盘回话时 isolate 照常处理别的事件。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_backfill_ledger.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_source.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:path/path.dart' as p;

/// 假网络盘路径标记（跨平台：只看路径里有没有这一段）。
const String _kNetSegment = '__fushi_net_mount__';

bool _isNetPath(String path) => path.contains(_kNetSegment);

class _FakeNetMount {
  _FakeNetMount(this.files);

  /// 网络盘上存在的文件：路径 → 内容。
  final Map<String, String> files;
  final List<String> syncCalls = <String>[];
  final List<String> asyncCalls = <String>[];
  final Completer<void> gate = Completer<void>();
}

class _NetFile implements File {
  _NetFile(this.path, this.mount);

  @override
  final String path;
  final _FakeNetMount mount;

  @override
  Future<bool> exists() async {
    mount.asyncCalls.add('exists $path');
    await mount.gate.future;
    return mount.files.containsKey(path);
  }

  @override
  Future<FileStat> stat() async {
    mount.asyncCalls.add('stat $path');
    await mount.gate.future;
    final String? content = mount.files[path];
    return _NetStat(
      content == null
          ? FileSystemEntityType.notFound
          : FileSystemEntityType.file,
      content?.length ?? -1,
    );
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    mount.asyncCalls.add('readAsString $path');
    await mount.gate.future;
    return mount.files[path]!;
  }

  @override
  Future<Uint8List> readAsBytes() async {
    mount.asyncCalls.add('readAsBytes $path');
    await mount.gate.future;
    return Uint8List.fromList(utf8.encode(mount.files[path]!));
  }

  @override
  Directory get parent => Directory(p.dirname(path));

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
    mount.asyncCalls.add('list $path');
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
  );
}

/// 起 [work] 后先证明「等网络盘时 isolate 没被堵住」，再放闸等结果。
Future<T> _whileMountIsSlow<T>(
  _FakeNetMount mount,
  Future<T> Function() work,
) async {
  final Future<T> pending = work();
  bool timerRan = false;
  Timer.run(() => timerRan = true);
  await Future<void>.delayed(Duration.zero);
  expect(timerRan, isTrue, reason: '网络盘没回话期间 isolate 必须照常处理别的事件');
  mount.gate.complete();
  return pending;
}

void main() {
  final String dir = p.join(
    Directory.systemTemp.path,
    _kNetSegment,
    'anime',
    'Show',
  );
  final String video = p.join(dir, 'Show - 01.mkv');

  group('BUG-3704 网络盘上的视频：打开 / 补字幕 / 封面回填零同步文件调用', () {
    test('弹幕 sidecar：async 列目录找同名文件、async stat 判体积', () async {
      final String danmaku = p.join(dir, 'Show - 01.dandanplay.json');
      final _FakeNetMount mount = _FakeNetMount(<String, String>{
        video: 'v',
        danmaku: '{"comments": []}',
        p.join(dir, 'Other.danmaku.xml'): '<i/>',
      });
      final String? found = await _withNetMount(
        mount,
        () => _whileMountIsSlow(mount, () => findDanmakuSidecar(video)),
      );
      expect(found, p.normalize(danmaku));
      expect(mount.syncCalls, isEmpty);

      final _FakeNetMount tooBig = _FakeNetMount(<String, String>{
        danmaku: 'x' * 64,
      });
      final VideoDanmakuLoadResult result = await _withNetMount(
        tooBig,
        () => _whileMountIsSlow(
          tooBig,
          () => loadDanmakuSidecarFile(File(danmaku), maxBytes: 8),
        ),
      );
      expect(result.tooLarge, isTrue);
      expect(tooBig.syncCalls, isEmpty);
    });

    test('弹幕 sidecar：目录不在 → null（与旧实现一致），不抛', () async {
      final _FakeNetMount mount = _FakeNetMount(<String, String>{});
      mount.gate.complete();
      final String? found = await _withNetMount(
        mount,
        () => findDanmakuSidecar(p.join(dir, 'gone', 'x.mkv')),
      );
      expect(found, isNull);
      expect(mount.syncCalls, isEmpty);
    });

    test('封面回填失败账本：记账与判重试都只 async stat', () async {
      final _FakeNetMount mount = _FakeNetMount(<String, String>{video: 'v'});
      final CoverBackfillLedger ledger = CoverBackfillLedger.forTesting();
      await _withNetMount(mount, () async {
        await _whileMountIsSlow(
          mount,
          () => ledger.recordFailure(video, reason: 'extract-failed'),
        );
        expect(await ledger.shouldAttempt(video), isFalse);
      });
      expect(mount.syncCalls, isEmpty);
      expect(
        mount.asyncCalls.where((String c) => c.startsWith('stat ')),
        hasLength(2),
      );
    });

    test('自动补字幕：视频与 sidecar 判据全 async（已有 sidecar → 不补）', () async {
      final _FakeNetMount mount = _FakeNetMount(<String, String>{
        video: 'v',
        p.join(dir, 'Show - 01.ja.srt'):
            '1\n00:00:01,000 --> 00:00:02,000\nx\n',
      });
      final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
        registry: VideoSubtitleRegistry(const <VideoSubtitleProvider>[]),
      );
      final SubtitleBackfillResult result = await _withNetMount(
        mount,
        () => _whileMountIsSlow(
          mount,
          () => service.backfill(
            SubtitleBackfillTarget(
              bookUid: 'video/show-01',
              videoPath: video,
              media: VideoMediaReference(
                providerId: 'anilist',
                mediaId: '1',
                mediaKind: VideoMetadataMediaKind.tv,
                discoveryCategory: VideoDiscoveryCategory.anime,
                title: 'Show',
                season: 1,
                episode: 1,
              ),
            ),
          ),
        ),
      );
      expect(result.outcome, SubtitleBackfillOutcome.alreadyHasSubtitle);
      expect(mount.syncCalls, isEmpty);
      expect(mount.asyncCalls, contains('list $dir'));
    });
  });
}
