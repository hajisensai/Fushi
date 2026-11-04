import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_live_activities.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_snapshot.dart';

/// Dart 写的 JSON 与 Swift `Codable` 的契约：Swift 结构体里每个存储属性都必须在
/// Dart 的 JSON 里有同名键；非可选属性在「只填必填项」的 Dart 对象里也不能是 null
/// ——否则 `JSONDecoder` 整份快照解码失败，小组件静默变成空状态。
void main() {
  final String swiftDir = '${Directory.current.path}/apple/HomeWidgets/Shared';

  test('snapshot.json matches FushiWidgetSnapshot (full and minimal)', () {
    final Map<String, _SwiftStruct> structs = _parseSwiftStructs(
      File('$swiftDir/FushiWidgetSnapshot.swift').readAsStringSync(),
    );
    const HomeWidgetContinueItem item = HomeWidgetContinueItem(
      kind: HomeWidgetItemKind.book,
      id: 'reader_fushi/1',
      title: 'T',
      subtitle: 'S',
      url: 'fushi://continue/book%3A1',
    );
    const HomeWidgetStudyDay day = HomeWidgetStudyDay(
      streak: 3,
      streakCaption: 'c',
      todayLine: 'l',
      last7: <double>[0, 0, 0, 0, 0, 0, -1],
    );
    const HomeWidgetSnapshot minimal = HomeWidgetSnapshot(
      generatedAt: 1,
      labels: <String, String>{'k': 'v'},
      srs: HomeWidgetSrsSection(
        timeline: <HomeWidgetSrsEntry>[
          HomeWidgetSrsEntry(at: 1, due: 2, caption: 'c', inline: 'i'),
        ],
        newCount: 1,
        learning: 2,
        review: 3,
        url: 'fushi://srs/review',
      ),
      study: HomeWidgetStudySection(
        today: day,
        tomorrow: day,
        midnightAt: 2,
        heat: <int>[0],
        weekValue: 'w',
        weekCaption: 'wc',
        cardsValue: 'c',
        cardsCaption: 'cc',
        url: 'fushi://stats',
      ),
      continueItems: <HomeWidgetContinueItem>[item],
      word: HomeWidgetWord(term: '猫', meaning: 'cat', url: 'fushi://lookup'),
      audiobook: item,
    );
    final Map<String, Object?> json = minimal.toJson();
    expect(json['v'], kHomeWidgetSnapshotVersion);

    Map<String, Object?> obj(Object? v) => v! as Map<String, Object?>;
    final Map<String, Map<String, Object?>> byStruct =
        <String, Map<String, Object?>>{
          'FushiWidgetSnapshot': json,
          'Srs': obj(json['srs']),
          'SrsEntry': obj((obj(json['srs'])['timeline']! as List<Object?>)[0]),
          'Study': obj(json['study']),
          'StudyDay': obj(obj(json['study'])['today']),
          'ContinueItem': obj((json['continue']! as List<Object?>)[0]),
          'Word': obj(json['word']),
        };
    expect(structs.keys, containsAll(byStruct.keys));
    for (final MapEntry<String, Map<String, Object?>> e in byStruct.entries) {
      _expectMatches(structs[e.key]!, e.value);
    }
    // 版本号两边一致。
    expect(
      File('$swiftDir/FushiWidgetSnapshot.swift').readAsStringSync().contains(
        'currentVersion = $kHomeWidgetSnapshotVersion',
      ),
      isTrue,
    );
  });

  test('playback state matches FushiPlaybackContent', () {
    final Map<String, _SwiftStruct> structs = _parseSwiftStructs(
      File('$swiftDir/FushiActivityAttributes.swift').readAsStringSync(),
    );
    const PlaybackActivityState state = PlaybackActivityState(
      title: 't',
      subtitle: 's',
      line: 'l',
      isPlaying: true,
      progress: 0.5,
      elapsedLabel: '0:01',
      remainingLabel: '-0:02',
    );
    _expectMatches(structs['FushiPlaybackContent']!, state.toJson());
  });

  test('every item kind has a widget symbol', () {
    final String timeline = File(
      '${Directory.current.path}/apple/HomeWidgets/Extension/FushiWidgetTimeline.swift',
    ).readAsStringSync();
    for (final HomeWidgetItemKind kind in HomeWidgetItemKind.values) {
      if (kind == HomeWidgetItemKind.book) continue; // default 分支
      expect(
        timeline.contains('case "${kind.name}"'),
        isTrue,
        reason: kind.name,
      );
    }
  });
}

void _expectMatches(_SwiftStruct s, Map<String, Object?> json) {
  for (final MapEntry<String, bool> field in s.fields.entries) {
    expect(
      json.containsKey(field.key),
      isTrue,
      reason: '${s.name}.${field.key} missing from Dart JSON',
    );
    if (!field.value) {
      expect(
        json[field.key],
        isNotNull,
        reason: '${s.name}.${field.key} is non-optional in Swift',
      );
    }
  }
}

class _SwiftStruct {
  _SwiftStruct(this.name, this.fields);
  final String name;

  /// 属性名 → 是否可选。
  final Map<String, bool> fields;
}

/// 极简 Swift 解析：取每个 `struct X ... {}` 的直接存储属性（`var a: T`，跳过嵌套
/// 结构体与计算属性）。
Map<String, _SwiftStruct> _parseSwiftStructs(String src) {
  final Map<String, _SwiftStruct> out = <String, _SwiftStruct>{};
  final RegExp head = RegExp(r'struct\s+(\w+)[^{]*\{');
  for (final RegExpMatch m in head.allMatches(src)) {
    int depth = 1;
    int i = m.end;
    final StringBuffer direct = StringBuffer();
    while (i < src.length && depth > 0) {
      final String c = src[i];
      if (c == '{') depth++;
      if (c == '}') depth--;
      if (depth == 1 && c != '}') direct.write(c);
      i++;
    }
    final Map<String, bool> fields = <String, bool>{};
    for (final RegExpMatch f in RegExp(
      r'^\s*var\s+`?(\w+)`?\s*:\s*([^\n{=]+?)\s*$',
      multiLine: true,
    ).allMatches(direct.toString())) {
      fields[f.group(1)!] = f.group(2)!.trim().endsWith('?');
    }
    out[m.group(1)!] = _SwiftStruct(m.group(1)!, fields);
  }
  return out;
}
