import 'dart:convert';

import 'package:fushi_engine/updates/debug_pulse.dart';
import 'package:test/test.dart';

/// 调试版流水线数据（`debug-pulse-fushi.json`，契约见
/// `docs/specs/2026-11-10-debug-pulse.md`）的解析与「相对本机」派生。
void main() {
  Map<String, Object?> platforms(Map<String, String> states) =>
      <String, Object?>{
        for (final MapEntry<String, String> e in states.entries)
          e.key: <String, Object?>{'state': e.value},
      };

  String sample({Object? schema = 1, Object? pending}) =>
      jsonEncode(<String, Object?>{
        'schema': schema,
        'generatedAt': '2026-11-10T08:00:00Z',
        'repo': 'hajisensai/Fushi',
        'develop': <String, Object?>{'sha': 'f' * 40, 'seq': 25048},
        // 故意乱序：客户端自己按 seq 降序排。
        'builds': <Object?>[
          <String, Object?>{
            'seq': 25010,
            'version': '3.3.0',
            'sha': 'b' * 40,
            'publishedAt': '2026-11-10T03:00:00Z',
            'baseSeq': 25005,
            'prs': <int>[3090],
            'direct': <Object?>[],
            'platforms': platforms(<String, String>{
              'android': 'superseded',
              'windows': 'ok',
              'macos': 'ok',
              'ios': 'ok',
            }),
          },
          <String, Object?>{
            'seq': 25034,
            'version': '3.3.0',
            'sha': 'a' * 40,
            'publishedAt': '2026-11-10T04:00:00Z',
            'testflight': true,
            'baseSeq': 25010,
            'prs': <int>[3101, 3100, 3090],
            'direct': <Object?>[
              <String, Object?>{'sha': 'c' * 40, 'subject': 'docs: typo'},
            ],
            'platforms': platforms(<String, String>{
              'android': 'ok',
              'windows': 'building',
              'macos': 'ok',
              'ios': 'ok',
            }),
          },
          <String, Object?>{
            'seq': 25005,
            'version': '3.3.0',
            'sha': null,
            'prs': <int>[],
            'platforms': <String, Object?>{},
          },
        ],
        'pending': pending,
        'prs': <String, Object?>{
          '3101': <String, Object?>{
            'number': 3101,
            'title': 'feat(server): redesign the admin WebUI',
            'author': 'samutw',
            'mergedAt': '2026-11-10T05:00:00Z',
            'additions': 830,
            'deletions': 285,
            'labels': <String>['server'],
          },
          '3100': <String, Object?>{
            'number': 3100,
            'title': 'fix: crash on start',
            'author': 'W1ght',
          },
        },
      });

  group('tryParse', () {
    test('按 seq 降序；sha 为 null 的包标 unknown；平台状态映射', () {
      final DebugPulseReport r = DebugPulseReport.tryParse(sample())!;
      expect(r.builds.map((DebugPulseBuild b) => b.seq), <int>[
        25034,
        25010,
        25005,
      ]);
      expect(r.latest!.label, 'debug.25034');
      expect(r.latest!.testflight, isTrue);
      expect(r.latest!.direct.single.subject, 'docs: typo');
      expect(r.builds.last.unknown, isTrue);
      expect(
        r.latest!.platform(DebugPulsePlatform.windows).state,
        DebugPulsePlatformState.building,
      );
      expect(
        r.builds.last.platform(DebugPulsePlatform.ios).state,
        DebugPulsePlatformState.none,
        reason: '缺平台键当作没包',
      );
      expect(r.pending, isNull);
    });

    test('schema 不认识 / 不是 JSON / 顶层不是对象 → null', () {
      expect(DebugPulseReport.tryParse(sample(schema: 2)), isNull);
      expect(DebugPulseReport.tryParse('<html>'), isNull);
      expect(DebugPulseReport.tryParse('[]'), isNull);
    });

    test('未知平台 state 落到 none，不抛', () {
      expect(
        DebugPulsePlatformState.fromWire('exploded'),
        DebugPulsePlatformState.none,
      );
    });

    test('pending 解析；没有 PR 也没有直推时 isEmpty', () {
      final DebugPulseReport r = DebugPulseReport.tryParse(
        sample(
          pending: <String, Object?>{
            'headSha': 'f' * 40,
            'headSeq': 25048,
            'prs': <int>[3101],
            'platforms': platforms(<String, String>{'android': 'queued'}),
          },
        ),
      )!;
      expect(r.pending!.headSeq, 25048);
      expect(r.pending!.isEmpty, isFalse);
      expect(
        r.pending!.platform(DebugPulsePlatform.android).state,
        DebugPulsePlatformState.queued,
      );
      final DebugPulseReport empty = DebugPulseReport.tryParse(
        sample(pending: <String, Object?>{'headSha': 'f' * 40}),
      )!;
      expect(empty.pending!.isEmpty, isTrue);
    });
  });

  group('相对本机', () {
    final DebugPulseReport r = DebugPulseReport.tryParse(sample())!;

    test('比本机新的包与去重后的 PR 数', () {
      expect(r.newerThan(25005).map((DebugPulseBuild b) => b.seq), <int>[
        25034,
        25010,
      ]);
      expect(r.newPrCount(25005), 3, reason: '3090 在两个包里各出现一次，只算一个');
      expect(r.newerThan(25034), isEmpty);
    });

    test('本机 seq 未知：不标任何包为新', () {
      expect(r.newerThan(null), isEmpty);
      expect(r.newPrCount(null), 0);
    });

    test('本机平台能更新到的 = 最新一个该平台真出了包的', () {
      expect(r.latestAvailableFor(DebugPulsePlatform.android)!.seq, 25034);
      expect(
        r.latestAvailableFor(DebugPulsePlatform.windows)!.seq,
        25010,
        reason: '25034 的 Windows 包还在构建',
      );
      expect(r.latestAvailableFor(null)!.seq, 25034);
    });
  });

  group('PR 标题', () {
    final DebugPulseReport r = DebugPulseReport.tryParse(sample())!;

    test('conventional 前缀 → 类别 + scope + 去前缀标题', () {
      final DebugPulsePr pr = r.pr(3101);
      expect(pr.kind, DebugPulsePrKind.feature);
      expect(pr.scope, 'server');
      expect(pr.displayTitle, 'redesign the admin WebUI');
      expect(r.pr(3100).kind, DebugPulsePrKind.fix);
      expect(r.pr(3100).scope, isNull);
    });

    test('没有前缀：其他、标题原样；缺元数据的编号给占位', () {
      final DebugPulsePr placeholder = r.pr(3090);
      expect(placeholder.title, '#3090');
      expect(placeholder.kind, DebugPulsePrKind.other);
      expect(r.prUrl(3090), 'https://github.com/hajisensai/Fushi/pull/3090');
    });
  });
}
