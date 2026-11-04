import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/app_shortcuts.dart';
import 'package:fushi/src/platform/home_widgets/live_activity_controller.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';

/// iOS / macOS 小组件与 Dart 之间的跨语言契约（Swift 在 Windows / Linux CI 上编不了，靠读源码
/// 守住）：
/// - Swift 解码的快照字段都真在 Dart `buildWidgetSnapshot()` 的输出里（同一份 JSON，
///   Android 与 Apple 共用，不许再长出第二套 schema）；契约版本一致。
/// - Swift 组件里取的每个 `labels` 键都在 [kWidgetLabelKeys] 里（Dart 真的会发）。
/// - Swift 里写死的每条 `fushi://` 链接都能被 Dart 的 [WidgetLink] / [AppShortcut] 解析。
/// - Live Activity 的 JSON（[PlaybackActivityState] / [TaskActivityState]）与 Swift 结构体
///   字段逐个对应。
void main() {
  const String appleDir = 'apple/HomeWidgets';
  final String snapshotSwift = File(
    '$appleDir/Shared/FushiWidgetSnapshot.swift',
  ).readAsStringSync();

  List<File> swiftSources() =>
      Directory(appleDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.swift'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  /// 每个 `init(from decoder:)` 里解码的键，按所属 struct 归组（按花括号深度追踪 struct 栈）。
  Map<String, Set<String>> decodedKeysByStruct(String source) {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    final RegExp structDecl = RegExp(r'struct (\w+)[^{]*\{');
    final RegExp keyUse = RegExp(r'(?:c\.\w+\(|AnyKey\()"(\w+)"');
    final List<String?> stack = <String?>[];
    String? pendingStruct;
    int i = 0;
    while (i < source.length) {
      final Match? decl = structDecl.matchAsPrefix(source, i);
      if (decl != null) {
        pendingStruct = decl.group(1);
        i = decl.end - 1; // 落到 `{` 上，下面统一入栈。
      }
      final String ch = source[i];
      if (ch == '{') {
        stack.add(pendingStruct);
        pendingStruct = null;
      } else if (ch == '}') {
        stack.removeLast();
      } else if (source.startsWith('init(from decoder: Decoder)', i)) {
        final String owner = stack.lastWhere((String? s) => s != null)!;
        final int bodyStart = source.indexOf('{', i);
        int depth = 0;
        int j = bodyStart;
        for (; j < source.length; j++) {
          if (source[j] == '{') depth++;
          if (source[j] == '}' && --depth == 0) break;
        }
        final String body = source.substring(bodyStart, j);
        out
            .putIfAbsent(owner, () => <String>{})
            .addAll(keyUse.allMatches(body).map((Match m) => m.group(1)!));
      }
      i++;
    }
    return out;
  }

  Map<String, Object?> fullSnapshot() => buildWidgetSnapshot(
    day: '2026-10-23',
    generatedAt: 1000,
    labels: WidgetSnapshotLabels(<String, String>{
      for (final String key in kWidgetLabelKeys) key: key,
    }),
    modules: const WidgetModulesInput(),
    media: const <WidgetMediaInput>[
      WidgetMediaInput(
        kind: WidgetMediaKind.book,
        id: 'b1',
        title: 'Book',
        subtitle: 'Author',
        progress: 0.5,
        coverPath: '/covers/b1.png',
        recentAt: 10,
        remainingMs: 3600000,
      ),
    ],
    immersion: const WidgetImmersionInput(
      msByDay: <String, Map<WidgetImmersionCategory, int>>{
        '2026-10-23': <WidgetImmersionCategory, int>{
          WidgetImmersionCategory.reading: 600000,
        },
      },
      activeDays: <String>{'2026-10-23'},
    ),
    goals: const WidgetGoalsInput(totalMinutes: 30),
    srs: const WidgetSrsInput(
      provider: WidgetSrsProvider.fushi,
      newCount: 1,
      learnCount: 2,
      reviewCount: 3,
      reviewedToday: 4,
    ),
    vocab: const <WidgetVocabInput>[
      WidgetVocabInput(
        term: '言葉',
        reading: 'ことば',
        definition: 'word',
        sentence: 's',
        source: 'src',
        origin: 'mined',
        createdAt: 1,
      ),
    ],
    nowPlaying: const WidgetNowPlayingInput(
      kind: WidgetNowPlayingKind.audiobook,
      title: 'Audiobook',
      link: 'fushi://widget/open',
      updatedAt: 1,
      durationMs: 100,
      positionMs: 10,
      playing: true,
    ),
    hideTitles: true,
    formatTime: (int ms) => '${ms ~/ 60000}m',
    formatChars: (int n) => '$n',
    formatCount: (int n) => '$n',
    formatAge: (int ms) => 'ago',
    weekdayLabel: (String key) => key,
  );

  test('Swift decodes the same snapshot version Dart publishes', () {
    final RegExpMatch? version = RegExp(
      r'static let currentVersion = (\d+)',
    ).firstMatch(snapshotSwift);
    expect(version, isNotNull);
    expect(int.parse(version!.group(1)!), kWidgetSnapshotVersion);
  });

  test('every snapshot field Swift decodes exists in the Dart snapshot', () {
    final Map<String, Object?> snapshot = fullSnapshot();
    Map<String, Object?> block(String key) =>
        snapshot[key]! as Map<String, Object?>;
    Map<String, Object?> first(String key) =>
        (snapshot[key]! as List<Object?>).first! as Map<String, Object?>;
    final Map<String, Map<String, Object?>> jsonByStruct =
        <String, Map<String, Object?>>{
          'FushiWidgetSnapshot': snapshot,
          'Privacy': block('privacy'),
          'Media': first('shelf'),
          'Today': block('today'),
          'Month': block('month'),
          'Streak': block('streak'),
          'Srs': block('srs'),
          'Vocab': first('vocab'),
          'NowPlaying': block('nowPlaying'),
        };
    final Map<String, Set<String>> swift = decodedKeysByStruct(snapshotSwift);
    expect(swift.keys.toSet(), jsonByStruct.keys.toSet());
    for (final MapEntry<String, Set<String>> e in swift.entries) {
      expect(
        jsonByStruct[e.key]!.keys.toSet(),
        containsAll(e.value),
        reason: 'Swift ${e.key} decodes keys the Dart snapshot does not send',
      );
    }
  });

  test('every labels key the Swift widgets read is published by Dart', () {
    final RegExp labelUse = RegExp(r'''(?:label\(|labels\[)"(\w+)"''');
    final Set<String> used = <String>{
      for (final File f in swiftSources())
        ...labelUse
            .allMatches(f.readAsStringSync())
            .map((Match m) => m.group(1)!),
    };
    expect(used, isNotEmpty);
    expect(kWidgetLabelKeys.toSet(), containsAll(used));
  });

  test(
    'every fushi:// link the Swift side hard-codes is understood by Dart',
    () {
      final RegExp link = RegExp(r'"(fushi://[^"\\]+)"');
      final Set<String> links = <String>{
        for (final File f in swiftSources())
          ...link
              .allMatches(f.readAsStringSync())
              .map((Match m) => m.group(1)!),
      };
      expect(links, isNotEmpty);
      for (final String url in links) {
        final bool understood =
            WidgetLink.tryParse(url) != null ||
            AppShortcut.tryParse(url) != null;
        expect(understood, isTrue, reason: '$url has no Dart landing');
      }
      // Swift 现拼的两种（continue / lookup）与 Dart 构造的同形。
      expect(
        WidgetLink.tryParse('fushi://widget/continue?kind=book&id=a%20b'),
        const WidgetContinueLink(kind: WidgetMediaKind.book, id: 'a b'),
      );
      expect(
        WidgetLink.tryParse('fushi://widget/lookup?word=%E8%A8%80'),
        const WidgetLookupLink('言'),
      );
    },
  );

  test(
    'Live Activity JSON matches the Swift content structs field by field',
    () {
      final String attributes = File(
        '$appleDir/Shared/FushiActivityAttributes.swift',
      ).readAsStringSync();
      Set<String> swiftFields(String structName) {
        final int start = attributes.indexOf('struct $structName:');
        expect(start, isNonNegative, reason: '$structName not found');
        final int end = attributes.indexOf('\n}', start);
        return RegExp(r'^\s*var (\w+):', multiLine: true)
            .allMatches(attributes.substring(start, end))
            .map((Match m) => m.group(1)!)
            .toSet();
      }

      const PlaybackActivityState playback = PlaybackActivityState(
        title: 't',
        subtitle: 's',
        line: 'l',
        isPlaying: true,
        progress: 0,
        elapsedLabel: '0:00',
        remainingLabel: '-0:00',
      );
      const TaskActivityState task = TaskActivityState(
        title: 't',
        detail: 'd',
        progress: 0,
        percentLabel: '0%',
        finished: false,
      );
      expect(
        playback.toJson().keys.toSet(),
        swiftFields('FushiPlaybackContent'),
      );
      expect(task.toJson().keys.toSet(), swiftFields('FushiTaskContent'));
    },
  );
}
