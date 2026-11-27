import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// BUG-5605：视频播放在 UI isolate 上的路径不许同步碰文件系统。
///
/// 用户库里的视频常在网络 / 云盘挂载上（rclone / WinFsp 挂的 OpenList、SMB、NFS）。
/// 这类卷的一次 stat 能在内核里等十几秒；在 UI isolate 上同步 `existsSync` 就是整个界面
/// 冻住（实测 hang dump：主线程停在 `Builtin_File_Exists` 7～23 s，调用方是进度条缩略图
/// 预取）。媒体文件「在不在」一律走有界异步探测（`media_path_probe.dart` 的
/// `probeMediaPath` / `video_member_file.dart` 的 `probeVideoMember` /
/// `probeLocalMediaFile`），超时按「暂不可用」处理。
///
/// 两层：
///
/// 1. [_uiPathFiles]：播放页、播放控制器、缩略图取帧、起播存在性检查——整份文件不许出现
///    任何同步文件 IO（不分媒体文件还是临时文件：这些代码只在 UI isolate 上跑）。
/// 2. [_mediaScanRoots]：视频相关目录与 ffmpeg 抽取器——不许对媒体输入路径同步判存在
///    （`videoMemberExistsSync` 等同步入口，或 `File(<…inputPath|videoPath|…>)` 直接接
///    `…Sync(`）。这些函数由播放页 / 制卡 / 字幕在 UI isolate 上调用。确实只在后台
///    isolate / CLI 里跑的，在 [_mediaAllowed] 逐条登记理由。

/// 第 1 层：整份文件禁同步文件 IO（目录以 `/` 结尾表示递归）。
const List<String> _uiPathFiles = <String>[
  'fushi/lib/src/pages/implementations/video_fushi_page.dart',
  'fushi/lib/src/pages/implementations/video_fushi/',
  'fushi/lib/src/media/video/video_thumbnail_preview_controller.dart',
  'fushi/lib/src/media/video/video_player_controller.dart',
  'fushi/lib/src/media/video/video_resource_check.dart',
  'fushi/lib/src/media/video/video_screenshot_filename.dart',
  'fushi/lib/src/media/video/subtitle_embedded_fonts.dart',
];

/// 第 2 层的扫描范围。
const List<String> _mediaScanRoots = <String>[
  'fushi/lib/src/media/video/',
  'fushi/lib/src/pages/implementations/',
  'packages/fushi_engine/lib/media/video/',
  'packages/fushi_engine/lib/utils/misc/desktop_audio_clipper.dart',
];

/// 第 2 层豁免：文件 → 理由。
const Map<String, String> _mediaAllowed = <String, String>{
  'packages/fushi_engine/lib/media/video/video_member_file.dart':
      '同步入口的定义本身（给后台 isolate / CLI 用）',
  'packages/fushi_engine/lib/media/video/video_library_prune.dart':
      '默认判据 videoMemberExistsSync 只被 fushi_server 的库扫描 / admin API 用（无头'
      '服务端进程，不在 app 的 UI isolate 上）',
  'packages/fushi_engine/lib/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart':
      'videoSubtitleJobId 用文件字节数做任务目录身份，签名是同步的，牵动 ASR 字幕任务'
      '全链路（app / host / 服务端）。不在播放路径上（只在发起 / 估算识别任务时算），'
      '异步化登记在 BUG-5605「未完成」，改完删掉本条',
};

final RegExp _anySyncFileIo = RegExp(
  r'\.\s*(existsSync|statSync|lengthSync|readAsBytesSync|readAsStringSync|'
  r'readAsLinesSync|openSync|lastModifiedSync|setLastModifiedSync|listSync|'
  r'writeAsStringSync|writeAsBytesSync|createSync|deleteSync|renameSync|'
  r'copySync|resolveSymbolicLinksSync)\s*\(|'
  r'FileSystemEntity\s*\.\s*(typeSync|isFileSync|isDirectorySync|'
  r'isLinkSync|identicalSync)\s*\(|FileStat\s*\.\s*statSync\s*\(',
);

final RegExp _mediaSyncProbe = RegExp(
  r'(?<![\w$])(videoMemberExistsSync|hasLocalMediaFileSync|'
  r'hasLocalSingleMediaFileSync|videoPathFileExistsSync)(?![\w$])|'
  r'File\(\s*[\w.!?]*(?:[iI]nputPath|[aA]udioPath|[vV]ideoPath|[mM]ediaPath)'
  r'\s*\)\s*\.\s*\w+Sync\s*\(',
);

/// 第 1 层判据：[source]（注释与字符串已遮罩）里的同步文件 IO 调用。
List<String> findSyncFileIo(String source) => <String>[
  for (final RegExpMatch m in _anySyncFileIo.allMatches(
    maskCommentsAndStrings(source),
  ))
    m.group(0)!,
];

/// 第 2 层判据：[source] 里对媒体输入路径的同步判存在。
List<String> findSyncMediaProbes(String source) => <String>[
  for (final RegExpMatch m in _mediaSyncProbe.allMatches(
    maskCommentsAndStrings(source),
  ))
    m.group(0)!,
];

Directory _repo() =>
    Directory(p.normalize(p.join(Directory.current.path, '..')));

String _rel(Directory repo, String path) =>
    p.relative(path, from: repo.path).replaceAll('\\', '/');

Iterable<File> _dartFiles(Directory repo, String entry) sync* {
  if (entry.endsWith('/')) {
    final Directory dir = Directory(p.join(repo.path, entry));
    expect(dir.existsSync(), isTrue, reason: '扫描根不存在：${dir.path}');
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File &&
          e.path.endsWith('.dart') &&
          !e.path.endsWith('.g.dart')) {
        yield e;
      }
    }
    return;
  }
  final File file = File(p.join(repo.path, entry));
  expect(file.existsSync(), isTrue, reason: '扫描目标不存在：${file.path}');
  yield file;
}

void main() {
  test('判据自检：同步 IO / 同步媒体探测能抓到，注释与异步写法不算', () {
    expect(findSyncFileIo('if (File(x).existsSync()) {}'), hasLength(1));
    expect(findSyncFileIo('f.lengthSync(); dir.listSync();'), hasLength(2));
    expect(findSyncFileIo('FileSystemEntity.typeSync(p);'), hasLength(1));
    expect(
      findSyncFileIo(
        '// 反例：File(x).existsSync()\n'
        "final String s = 'existsSync()';\n"
        'await File(x).exists(); await f.length();',
      ),
      isEmpty,
    );
    expect(
      findSyncMediaProbes('videoMemberExistsSync(inputPath)'),
      hasLength(1),
    );
    expect(
      findSyncMediaProbes('exists ?? videoMemberExistsSync;'),
      hasLength(1),
      reason: 'tear-off 当默认值也是同步探测',
    );
    expect(
      findSyncMediaProbes('if (!File(inputPath).existsSync()) return null;'),
      hasLength(1),
    );
    expect(
      findSyncMediaProbes('if (File(widget.videoPath).lengthSync() > 0) {}'),
      hasLength(1),
    );
    expect(
      findSyncMediaProbes(
        'await probeVideoMember(inputPath);\n'
        'staged.existsSync();\n'
        '// videoMemberExistsSync(x)',
      ),
      isEmpty,
      reason: '临时输出文件不归第 2 层管；注释不算',
    );
  });

  test('播放 UI 路径整份文件不许同步文件 IO（第 1 层）', () {
    final Directory repo = _repo();
    int scanned = 0;
    final Map<String, List<String>> offenders = <String, List<String>>{};
    for (final String entry in _uiPathFiles) {
      for (final File f in _dartFiles(repo, entry)) {
        scanned++;
        final List<String> hits = findSyncFileIo(f.readAsStringSync());
        if (hits.isNotEmpty) offenders[_rel(repo, f.path)] = hits;
      }
    }
    expectScanScale(
      scanned,
      what: '播放 UI 路径的 .dart 文件',
      atLeast: 20,
      measured: 34,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件只在 UI isolate 上跑，同步文件 IO 遇上网络盘就是整窗冻结（BUG-5605）。'
          '媒体文件判存在用 probeVideoMember / probeLocalMediaFile / probeMediaPath'
          '（有界、三态），其它文件用 await File(..).exists() / length() / delete()。',
    );
  });

  test('视频相关目录不许对媒体输入路径同步判存在（第 2 层）', () {
    final Directory repo = _repo();
    int scanned = 0;
    final Map<String, List<String>> offenders = <String, List<String>>{};
    final Set<String> allowedSeen = <String>{};
    final Set<String> seen = <String>{};
    for (final String entry in _mediaScanRoots) {
      for (final File f in _dartFiles(repo, entry)) {
        final String rel = _rel(repo, f.path);
        if (!seen.add(rel)) continue;
        scanned++;
        final List<String> hits = findSyncMediaProbes(f.readAsStringSync());
        if (hits.isEmpty) continue;
        if (_mediaAllowed.containsKey(rel)) {
          allowedSeen.add(rel);
          continue;
        }
        offenders[rel] = hits;
      }
    }
    expectScanScale(
      scanned,
      what: '视频相关目录的 .dart 文件',
      atLeast: 500,
      measured: 900,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '媒体输入常在网络盘上，同步 stat 会冻住调用它的 UI isolate（BUG-5605）。'
          '用 probeVideoMember / probeLocalMediaFile / probeMediaPath（有界异步，'
          '超时答 unavailable，不当成文件丢失）。确实只在后台 isolate / CLI 跑的登记进 '
          '_mediaAllowed。',
    );
    expect(
      allowedSeen,
      _mediaAllowed.keys.toSet(),
      reason: '白名单里有已经不再命中的条目：删掉它，别让豁免悄悄变宽',
    );
  });
}
