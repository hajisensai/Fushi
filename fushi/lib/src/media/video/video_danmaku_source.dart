import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart'
    show DanmakuNative, DanmakuParseOutcome, DanmakuParseResult;
import 'package:fushi/src/media/video/video_danmaku_model.dart';

const List<String> _danmakuSidecarSuffixes = <String>[
  '.danmaku.xml',
  '.bilibili.xml',
  '.xml',
  '.dandanplay.json',
  '.danmaku.json',
  '.json',
];

String? pickDanmakuSidecar(String videoBaseNameNoExt, List<String> dirFiles) {
  final String baseLower = videoBaseNameNoExt.toLowerCase();
  for (final String suffix in _danmakuSidecarSuffixes) {
    final String wantLower = '$baseLower$suffix';
    for (final String name in dirFiles) {
      if (name.toLowerCase() == wantLower) return name;
    }
  }
  return null;
}

/// 视频同目录的同名弹幕 sidecar（无则 null）。
///
/// async：视频常在网络盘（rclone / SMB 挂载）上，同步 listSync 冷目录时要逐级重列
/// 目录、单次数秒，会冻结 UI isolate 与同 isolate 的互联 host（BUG-3756）。目录不存在
/// / 无权限时与旧实现一致返回 null。
Future<String?> findDanmakuSidecar(String videoPath) async {
  final Directory dir = Directory(p.dirname(videoPath));
  final List<String> files = <String>[];
  try {
    await for (final FileSystemEntity e in dir.list(followLinks: false)) {
      if (e is File) files.add(p.basename(e.path));
    }
  } on FileSystemException {
    return null;
  }
  final String? picked = pickDanmakuSidecar(
    p.basenameWithoutExtension(videoPath),
    files,
  );
  return picked == null ? null : p.normalize(p.join(dir.path, picked));
}

Future<VideoDanmakuLoadResult> loadDanmakuSidecarFile(
  File file, {
  int maxBytes = kVideoDanmakuLocalMaxBytes,
}) async {
  try {
    // 一次 async stat 拿存在性与体积（BUG-3756：sidecar 在网络盘上时同步 stat 冻结 UI）。
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      return VideoDanmakuLoadResult(
        items: const <VideoDanmakuItem>[],
        sourcePath: file.path,
      );
    }
    final int length = stat.size;
    if (length > maxBytes) {
      return VideoDanmakuLoadResult(
        items: const <VideoDanmakuItem>[],
        sourcePath: file.path,
        tooLarge: true,
      );
    }
    // IO（读盘 + 编码探测）留在主 isolate；CPU 密集解析（原生 fushi_compute 解析 +
    // 逐条重建 Dart 对象，20MB sidecar 可卡帧）搬进后台 isolate。
    // 入参 (String, bool) 与出参 List<VideoDanmakuItem>（纯 int/String/enum 数据类）
    // 均可跨 isolate 传输，`_parseDanmakuContent` 是无闭包捕获的顶层纯函数。
    final String content = await readTextWithEncoding(file);
    final String ext = p.extension(file.path).toLowerCase();
    final List<VideoDanmakuItem> items = await compute(_parseDanmakuContent, (
      content,
      ext == '.json',
    ));
    return VideoDanmakuLoadResult(items: items, sourcePath: file.path);
  } catch (e) {
    return VideoDanmakuLoadResult(
      items: const <VideoDanmakuItem>[],
      sourcePath: file.path,
      error: e,
    );
  }
}

/// [compute] 入口（顶层、无闭包捕获）：按 `isJson` 标记把 sidecar 文本分派给
/// 弹弹play JSON / Bilibili XML 解析器。放后台 isolate 避免 20MB 文件卡主线程。
List<VideoDanmakuItem> _parseDanmakuContent((String, bool) request) {
  final (String content, bool isJson) = request;
  return isJson
      ? parseDandanplayDanmakuJson(content)
      : parseBilibiliDanmakuXml(content);
}

/// 弹幕解析的唯一实现在原生 `fushi_compute`（`DanmakuNative`，
/// native/fushi_compute/src/parse/danmaku.rs）：它逐位复刻了旧 Dart 实现
/// （`package:xml` / `jsonDecode` + 逐条转换 + `List.sort`）的结果，冻结向量见
/// packages/fushi_compute/test/danmaku_parity_test.dart。原生库是硬依赖，缺失时抛
/// `FushiComputeUnavailableError`（不是解析失败，不吞成空表）。
VideoDanmakuItem _danmakuItem(
  int startMs,
  String text,
  int mode,
  int colorArgb,
) {
  return VideoDanmakuItem(
    startMs: startMs,
    text: text,
    mode: VideoDanmakuMode.values[mode],
    colorArgb: colorArgb,
  );
}

/// Bilibili XML（`<d p="时间,模式,字号,颜色,…">文本</d>`）。XML 损坏或某条时间不是
/// 有限数时整份返回空表（与旧实现一致）。
List<VideoDanmakuItem> parseBilibiliDanmakuXml(String xml) {
  final DanmakuParseResult<VideoDanmakuItem> result = DanmakuNative.instance
      .parseBilibiliXml(xml, _danmakuItem);
  return result.outcome == DanmakuParseOutcome.ok
      ? result.items
      : const <VideoDanmakuItem>[];
}

/// 弹弹play JSON（`{"comments": [...]}`）。JSON 损坏、形状不对或数值非有限时返回空表。
List<VideoDanmakuItem> parseDandanplayDanmakuJson(
  String json, {
  int shiftMs = 0,
}) {
  final DanmakuParseResult<VideoDanmakuItem> result = DanmakuNative.instance
      .parseDandanplayJson(json, _danmakuItem, shiftMs: shiftMs);
  return result.outcome == DanmakuParseOutcome.ok
      ? result.items
      : const <VideoDanmakuItem>[];
}

/// 在线 `/api/v2/comment` 的响应体 → 弹幕（偏移按 `(shiftSeconds * 1000).round()`）。
///
/// 返回 null 表示形状不对（根不是对象或 `comments` 不是数组）；JSON 语法错误抛与
/// `jsonDecode` 相同的 [FormatException]；偏移或某条数值不是有限数时抛
/// `UnsupportedError('Infinity or NaN toInt')`——与旧的 `jsonDecode` + 形状校验 +
/// 逐条转换在同样的输入上抛同样的异常，调用方的状态分类不变。
List<VideoDanmakuItem>? dandanplayDanmakuFromResponseBody(
  String body, {
  required double shiftSeconds,
}) {
  final DanmakuParseResult<VideoDanmakuItem> result = DanmakuNative.instance
      .parseDandanplayJson(body, _danmakuItem, shiftSeconds: shiftSeconds);
  switch (result.outcome) {
    case DanmakuParseOutcome.ok:
      return result.items;
    case DanmakuParseOutcome.shapeError:
      return null;
    case DanmakuParseOutcome.syntaxError:
      throw result.formatException!;
    case DanmakuParseOutcome.nonFiniteNumber:
      throw UnsupportedError('Infinity or NaN toInt');
  }
}
