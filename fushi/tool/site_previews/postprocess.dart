// 官网预览素材后期：把 site_preview_capture_itest 的原始产物整理成官网要的文件。
//
//   dart run tool/site_previews/postprocess.dart --raw <原始产物目录> --site <官网仓>
//
// - overview-<页>.png（物理分辨率）→ <官网>/public/overview/<页>.jpg，1440×900
// - <场景>.timeline.json + 无声录屏 → <官网>/public/preview/<场景>.mp4（1280×720、
//   H.264 + AAC、faststart；尺寸取时间线的 outWidth/outHeight，漫画是竖版，按时间线把媒体原声混进去）与 <场景>-poster.jpg
//
// 只用 PATH 上的 ffmpeg。--dry-run 只打印要执行的命令。
import 'dart:convert';
import 'dart:io';

const int _kOverviewWidth = 1440;
const int _kOverviewHeight = 900;
const int _kPreviewWidth = 1280;
const int _kPreviewHeight = 720;

Future<void> main(List<String> args) async {
  final Map<String, String> opts = _parseArgs(args);
  final String? raw = opts['raw'];
  final String? site = opts['site'];
  if (raw == null || site == null) {
    stderr.writeln(
      '用法: postprocess.dart --raw <原始产物目录> --site <官网仓> [--dry-run]',
    );
    exit(64);
  }
  final bool dryRun = opts.containsKey('dry-run');
  final Directory rawDir = Directory(raw);
  final Directory overviewOut = Directory('$site/public/overview');
  final Directory previewOut = Directory('$site/public/preview');
  int produced = 0;

  for (final FileSystemEntity e in rawDir.listSync()..sort(_byPath)) {
    final String name = e.uri.pathSegments.last;
    final RegExpMatch? ov = RegExp(r'^overview-(\w+)\.png$').firstMatch(name);
    if (ov != null) {
      await _ffmpeg(<String>[
        '-i',
        e.path,
        '-vf',
        'scale=$_kOverviewWidth:$_kOverviewHeight:flags=lanczos',
        '-q:v',
        '3',
        '${overviewOut.path}/${ov.group(1)}.jpg',
      ], dryRun);
      produced++;
      continue;
    }
    final RegExpMatch? tl = RegExp(r'^(\w+)\.timeline\.json$').firstMatch(name);
    if (tl != null) {
      await _encodePreview(tl.group(1)!, File(e.path), previewOut, dryRun);
      produced++;
    }
  }
  if (produced == 0) {
    stderr.writeln('$raw 下没有 overview-*.png 或 *.timeline.json');
    exit(1);
  }
  stdout.writeln('完成：$produced 项 → $site/public');
}

int _byPath(FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path);

Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> out = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--')) continue;
    final String key = a.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out[key] = args[++i];
    } else {
      out[key] = '';
    }
  }
  return out;
}

/// 一段场景：缩放到录制时的逻辑尺寸（默认 1280×720），按时间线混入原声，出 mp4 与封面帧。
Future<void> _encodePreview(
  String scene,
  File timelineFile,
  Directory outDir,
  bool dryRun,
) async {
  final Map<String, Object?> tl =
      jsonDecode(await timelineFile.readAsString()) as Map<String, Object?>;
  final String video = tl['video']! as String;
  final List<Map<String, Object?>> audio = <Map<String, Object?>>[
    for (final Object? a in (tl['audio'] as List<Object?>? ?? <Object?>[]))
      a! as Map<String, Object?>,
  ];
  final int trimStartMs = (tl['trimStartMs'] as int?) ?? 0;
  final int? trimEndMs = tl['trimEndMs'] as int?;
  final int posterMs = (tl['posterMs'] as int?) ?? trimStartMs;
  // 成片尺寸 = 录制时的逻辑客户区（漫画是竖版）；旧时间线没写就按 16:9。
  final int outW = (tl['outWidth'] as int?) ?? _kPreviewWidth;
  final int outH = (tl['outHeight'] as int?) ?? _kPreviewHeight;

  final List<String> args = <String>[
    '-ss',
    _sec(trimStartMs),
    if (trimEndMs != null) ...<String>['-to', _sec(trimEndMs)],
    '-i',
    video,
  ];
  // 剪辑点（录制时间轴，毫秒）：查词等待等不进成片的段落，画面与混音同步剪掉。
  final List<String> cuts = <String>[
    for (final Object? c in (tl['cuts'] as List<Object?>? ?? <Object?>[]))
      _betweenExpr(c! as List<Object?>, trimStartMs),
  ];
  final String keep = cuts.isEmpty ? '' : "not(${cuts.join('+')})";
  final List<String> filters = <String>[
    '[0:v]fps=30,scale=$outW:$outH:flags=lanczos,'
        '${keep.isEmpty ? '' : "select='$keep',setpts=N/30/TB,"}'
        'format=yuv420p[v]',
  ];
  final List<String> mixInputs = <String>[];
  for (int i = 0; i < audio.length; i++) {
    final Map<String, Object?> a = audio[i];
    final int fromMs = (a['fromMs'] as int?) ?? 0;
    final int? durMs = a['durationMs'] as int?;
    args.addAll(<String>[
      '-ss',
      _sec(fromMs),
      if (durMs != null) ...<String>['-t', _sec(durMs)],
      '-i',
      a['file']! as String,
    ]);
    // 时间线的 atMs 以录制开始为零点；成片从 trimStartMs 起。
    final int delay = ((a['atMs']! as int) - trimStartMs).clamp(0, 1 << 30);
    filters.add(
      '[${i + 1}:a]aresample=48000,adelay=$delay|$delay,'
      'afade=t=out:st=${_sec((durMs ?? 600000) + delay - 250)}:d=0.25[a$i]',
    );
    mixInputs.add('[a$i]');
  }
  final bool hasAudio = mixInputs.isNotEmpty;
  if (hasAudio) {
    filters.add(
      '${mixInputs.join()}amix=inputs=${mixInputs.length}'
      // 原声比画面短：补静音到无穷，-shortest 再按画面长度截断。
      ':normalize=0:duration=longest,'
      '${keep.isEmpty ? '' : "aselect='$keep',asetpts=N/SR/TB,"}'
      'apad[a]',
    );
  }
  final String outMp4 = '${outDir.path}/$scene.mp4';
  await _ffmpeg(<String>[
    ...args,
    '-filter_complex',
    filters.join(';'),
    '-map',
    '[v]',
    if (hasAudio) ...<String>['-map', '[a]', '-c:a', 'aac', '-b:a', '96k'],
    if (!hasAudio) '-an',
    '-dn',
    '-shortest',
    '-c:v',
    'libx264',
    '-preset',
    'slow',
    '-crf',
    '27',
    '-r',
    '30',
    '-movflags',
    '+faststart',
    outMp4,
  ], dryRun);
  await _ffmpeg(<String>[
    '-ss',
    _sec(posterMs),
    '-i',
    video,
    '-frames:v',
    '1',
    '-vf',
    'scale=$outW:$outH:flags=lanczos',
    '-q:v',
    '4',
    '${outDir.path}/$scene-poster.jpg',
  ], dryRun);
}

/// 一个剪辑点 [fromMs, toMs]（录制时间轴）→ 成片时间轴上的 between(t,a,b)。
String _betweenExpr(List<Object?> cut, int trimStartMs) =>
    'between(t,${_sec((cut[0]! as int) - trimStartMs)},'
    '${_sec((cut[1]! as int) - trimStartMs)})';

String _sec(int ms) => (ms / 1000).toStringAsFixed(3);

Future<void> _ffmpeg(List<String> args, bool dryRun) async {
  final List<String> full = <String>[
    '-hide_banner',
    '-v',
    'error',
    '-y',
    ...args,
  ];
  stdout.writeln('ffmpeg ${full.join(' ')}');
  if (dryRun) return;
  final File target = File(args.last);
  await target.parent.create(recursive: true);
  final ProcessResult r = await Process.run('ffmpeg', full);
  if (r.exitCode != 0) {
    stderr.writeln(r.stderr);
    throw ProcessException('ffmpeg', full, 'exit ${r.exitCode}', r.exitCode);
  }
}
