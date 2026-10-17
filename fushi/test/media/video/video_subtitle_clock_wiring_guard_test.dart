import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3313 守卫：视频页里「按时间解析 / 绘制字幕」的调用点必须读字幕时钟
/// （`subtitleClockMs`），不许读原始 `positionMs`。
///
/// seek 刚发出时 player 吐的还是跳转前的旧位置，活动集已按跳转目标算好。这些调用点
/// 若仍读原始位置，跳转后就会按旧时间做事：制卡 / 收藏锚到跳转前那句、按位置调轴
/// 算出错误延迟、调轴面板播放头停在旧处、弹幕先画旧时刻。
///
/// 只扫调用名之后到配对右括号为止的实参文本；`positionMs` 作为参数名本身不算。
const List<String> _kCallsReadingSubtitleTime = <String>[
  'resolveMiningCueForPosition(',
  'resolveVideoLookupAnchorCue(',
  'snapSubtitleDelayMs(',
  'VideoDanmakuOverlay(',
];

const List<String> _kSubtitleTimeCallbacks = <String>[
  'currentSubtitlePositionMs:',
  'currentPositionMs:',
];

final RegExp _rawPosition = RegExp(
  r'(controller|_controller)\??\.positionMs\b',
);

/// 从 [open] 处（指向 `(` 之后）取到配对 `)` 为止的文本。
String _argsFrom(String src, int open) {
  int depth = 1;
  for (int i = open; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '(') depth++;
    if (ch == ')' && --depth == 0) return src.substring(open, i);
  }
  return src.substring(open);
}

/// 回调实参：取到行尾。
String _lineFrom(String src, int start) {
  final int end = src.indexOf('\n', start);
  return src.substring(start, end < 0 ? src.length : end);
}

List<File> _videoPageSources() {
  final Directory root = Directory('lib/src/pages/implementations');
  return <File>[
    File('${root.path}/video_fushi_page.dart'),
    ...Directory(
      '${root.path}/video_fushi',
    ).listSync().whereType<File>().where((File f) => f.path.endsWith('.dart')),
  ];
}

void main() {
  test('视频页字幕时间调用点读字幕时钟而非原始 positionMs', () {
    final List<String> offenders = <String>[];
    int hits = 0;
    for (final File file in _videoPageSources()) {
      final String src = file.readAsStringSync();
      for (final String call in _kCallsReadingSubtitleTime) {
        for (
          int at = src.indexOf(call);
          at >= 0;
          at = src.indexOf(call, at + 1)
        ) {
          hits++;
          final String args = _argsFrom(src, at + call.length);
          if (_rawPosition.hasMatch(args)) offenders.add('${file.path}: $call');
        }
      }
      for (final String cb in _kSubtitleTimeCallbacks) {
        for (int at = src.indexOf(cb); at >= 0; at = src.indexOf(cb, at + 1)) {
          hits++;
          if (_rawPosition.hasMatch(_lineFrom(src, at))) {
            offenders.add('${file.path}: $cb');
          }
        }
      }
    }
    expect(hits, greaterThanOrEqualTo(7), reason: '扫描面失效（调用点改名 / 搬家）');
    expect(offenders, isEmpty);
  });

  // 按有效流（miningCues）按位置取句时，时钟必须是 miningPositionMs：图形字幕时间表
  // 下它是真实位置（与控制器图形锚点按位置取句同一个时钟），文本流下才是字幕时钟。
  // 直接读 subtitleClockMs 会让图形模式同一次操作出现两个「当前句」。
  test('按 miningCues 取句的调用点读 miningPositionMs', () {
    final List<String> offenders = <String>[];
    int hits = 0;
    for (final File file in _videoPageSources()) {
      final String src = file.readAsStringSync();
      for (final String call in _kCallsReadingSubtitleTime) {
        for (
          int at = src.indexOf(call);
          at >= 0;
          at = src.indexOf(call, at + 1)
        ) {
          final String args = _argsFrom(src, at + call.length);
          if (!args.contains('.miningCues')) continue;
          hits++;
          if (!args.contains('.miningPositionMs')) {
            offenders.add('${file.path}: $call');
          }
        }
      }
    }
    expect(hits, greaterThanOrEqualTo(2), reason: '扫描面失效（调用点改名 / 搬家）');
    expect(offenders, isEmpty);
  });
}
