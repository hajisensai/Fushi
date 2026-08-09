import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:fushi_audio/fushi_audio.dart';
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

String? findDanmakuSidecar(String videoPath) {
  final Directory dir = Directory(p.dirname(videoPath));
  if (!dir.existsSync()) return null;
  final List<String> files;
  try {
    files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .toList(growable: false);
  } on FileSystemException {
    return null;
  }
  final String? picked =
      pickDanmakuSidecar(p.basenameWithoutExtension(videoPath), files);
  return picked == null ? null : p.normalize(p.join(dir.path, picked));
}

Future<VideoDanmakuLoadResult> loadDanmakuSidecarFile(
  File file, {
  int maxBytes = kVideoDanmakuLocalMaxBytes,
}) async {
  try {
    if (!file.existsSync()) {
      return VideoDanmakuLoadResult(
        items: const <VideoDanmakuItem>[],
        sourcePath: file.path,
      );
    }
    final int length = file.lengthSync();
    if (length > maxBytes) {
      return VideoDanmakuLoadResult(
        items: const <VideoDanmakuItem>[],
        sourcePath: file.path,
        tooLarge: true,
      );
    }
    // IO（读盘 + 编码探测）留在主 isolate；CPU 密集解析（XmlDocument.parse /
    // jsonDecode + 遍历 + sort，20MB sidecar 可卡帧）搬进后台 isolate。
    // 入参 (String, bool) 与出参 List<VideoDanmakuItem>（纯 int/String/enum 数据类）
    // 均可跨 isolate 传输，`_parseDanmakuContent` 是无闭包捕获的顶层纯函数。
    final String content = await readTextWithEncoding(file);
    final String ext = p.extension(file.path).toLowerCase();
    final List<VideoDanmakuItem> items = await compute(
      _parseDanmakuContent,
      (content, ext == '.json'),
    );
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

List<VideoDanmakuItem> parseBilibiliDanmakuXml(String xml) {
  try {
    final XmlDocument doc = XmlDocument.parse(xml);
    final List<VideoDanmakuItem> items = <VideoDanmakuItem>[];
    for (final XmlElement node in doc.findAllElements('d')) {
      final String? pValue = node.getAttribute('p');
      final String text = node.innerText.trim();
      final VideoDanmakuItem? item =
          _itemFromParts(pValue?.split(','), text, colorIndex: 3);
      if (item != null) items.add(item);
    }
    items.sort((VideoDanmakuItem a, VideoDanmakuItem b) =>
        a.startMs.compareTo(b.startMs));
    return items;
  } catch (_) {
    return const <VideoDanmakuItem>[];
  }
}

List<VideoDanmakuItem> parseDandanplayDanmakuJson(
  String json, {
  int shiftMs = 0,
}) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map) return const <VideoDanmakuItem>[];
    final dynamic rawComments = decoded['comments'];
    if (rawComments is! List) return const <VideoDanmakuItem>[];
    return dandanplayCommentsToDanmaku(rawComments, shiftMs: shiftMs);
  } catch (_) {
    return const <VideoDanmakuItem>[];
  }
}

List<VideoDanmakuItem> dandanplayCommentsToDanmaku(
  Iterable<dynamic> comments, {
  int shiftMs = 0,
}) {
  final List<VideoDanmakuItem> items = <VideoDanmakuItem>[];
  for (final dynamic row in comments) {
    if (row is! Map) continue;
    final String text = (row['m'] ?? row['text'] ?? '').toString().trim();
    if (text.isEmpty) continue;
    VideoDanmakuItem? item;
    final Object? pValue = row['p'];
    if (pValue is String) {
      item = _itemFromParts(pValue.split(','), text);
    } else {
      item = _itemFromObject(row, text);
    }
    if (item == null) continue;
    final int shifted = (item.startMs + shiftMs).clamp(0, 1 << 30).toInt();
    items.add(item.copyWith(startMs: shifted));
  }
  items.sort((VideoDanmakuItem a, VideoDanmakuItem b) =>
      a.startMs.compareTo(b.startMs));
  return items;
}

VideoDanmakuItem? _itemFromParts(
  List<String>? parts,
  String text, {
  int colorIndex = 2,
}) {
  if (parts == null || parts.length <= colorIndex || text.trim().isEmpty) {
    return null;
  }
  final double? seconds = double.tryParse(parts[0].trim());
  final int? rawMode = int.tryParse(parts[1].trim());
  final int? color = int.tryParse(parts[colorIndex].trim());
  if (seconds == null || rawMode == null || color == null) return null;
  final VideoDanmakuMode? mode = _modeFromRaw(rawMode);
  if (mode == null) return null;
  return VideoDanmakuItem(
    startMs: (seconds * 1000).round().clamp(0, 1 << 30).toInt(),
    text: text.trim(),
    mode: mode,
    colorArgb: _argbFromRgbInt(color),
  );
}

VideoDanmakuItem? _itemFromObject(Map<dynamic, dynamic> row, String text) {
  final Object? rawTime = row['time'] ?? row['t'] ?? row['start'];
  final double? seconds = rawTime is num
      ? rawTime.toDouble()
      : rawTime is String
          ? double.tryParse(rawTime)
          : null;
  if (seconds == null) return null;
  final Object? rawMode = row['mode'] ?? row['type'];
  final VideoDanmakuMode? mode = rawMode is num
      ? _modeFromRaw(rawMode.toInt())
      : rawMode is String
          ? _modeFromString(rawMode)
          : VideoDanmakuMode.scroll;
  if (mode == null) return null;
  final Object? rawColor = row['color'];
  final int color = rawColor is num ? rawColor.toInt() : 0xFFFFFF;
  return VideoDanmakuItem(
    startMs: (seconds * 1000).round().clamp(0, 1 << 30).toInt(),
    text: text,
    mode: mode,
    colorArgb: _argbFromRgbInt(color),
  );
}

VideoDanmakuMode? _modeFromRaw(int raw) {
  return switch (raw) {
    1 || 2 || 3 => VideoDanmakuMode.scroll,
    4 => VideoDanmakuMode.bottom,
    5 => VideoDanmakuMode.top,
    _ => null,
  };
}

VideoDanmakuMode? _modeFromString(String raw) {
  return switch (raw.toLowerCase()) {
    'scroll' || 'rolling' || 'right' => VideoDanmakuMode.scroll,
    'top' => VideoDanmakuMode.top,
    'bottom' => VideoDanmakuMode.bottom,
    _ => null,
  };
}

int _argbFromRgbInt(int rgb) => 0xFF000000 | (rgb & 0x00FFFFFF);
