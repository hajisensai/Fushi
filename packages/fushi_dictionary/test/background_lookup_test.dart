import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 后台查词里不依赖原生库的那几块：调度（最后输入为准）、后台原始结果缓存的淘汰
/// 与失效、缓存键、extra 编码的逐字节不变。真原生库上的端到端（后台结果 == 旧同步
/// 路径、重载与在飞查询并发）在 background_tokenize_native_test.dart。

/// 旧版 `buildLookupEntryExtra`（每条 glossary 整体 jsonEncode 一次）的原样拷贝，
/// 作新实现逐字节对照的参照物。
String _referenceExtra(FushiLookupResult r, FushiGlossaryEntry g) {
  return jsonEncode({
    'definitionTags': g.definitionTags,
    'termTags': g.termTags,
    'matched': r.matched,
    'deinflected': r.deinflected,
    'deinflectionTrace': deinflectionTagsToJson(
      buildDeinflectionTags(
        matched: r.matched,
        deinflected: r.deinflected,
        trace: r.trace,
      ),
    ),
    'frequencies': r.term.frequencies
        .map(
          (f) => {
            'dictName': f.dictName,
            'values': f.frequencies
                .map((v) => {'value': v.value, 'display': v.displayValue})
                .toList(),
          },
        )
        .toList(),
    'pitches': r.term.pitches
        .map(
          (p) => {
            'dictName': p.dictName,
            'positions': p.pitchPositions,
            'patterns': p.patterns,
            'transcriptions': p.transcriptions,
          },
        )
        .toList(),
  });
}

FushiLookupResult _lookupResult({
  String matched = '食べた',
  String deinflected = '食べる',
  String expression = '食べる',
  String reading = 'たべる',
  List<FushiTransformGroup> trace = const <FushiTransformGroup>[
    FushiTransformGroup(name: '-た', description: 'Past "quoted" \\ form'),
  ],
  List<FushiGlossaryEntry>? glossaries,
  int glossaryChars = 4,
}) {
  return FushiLookupResult(
    matched: matched,
    deinflected: deinflected,
    trace: trace,
    preprocessorSteps: 0,
    term: FushiTermResult(
      expression: expression,
      reading: reading,
      rules: 'v1',
      glossaries:
          glossaries ??
          <FushiGlossaryEntry>[
            FushiGlossaryEntry(
              dictName: 'A',
              glossary: jsonEncode('g' * glossaryChars),
              definitionTags: 'v1 "tag"',
              termTags: '',
            ),
          ],
      frequencies: const <FushiFrequencyEntry>[
        FushiFrequencyEntry(
          dictName: 'F',
          frequencies: <FushiFrequency>[
            FushiFrequency(value: 12, displayValue: '12㋕'),
          ],
        ),
      ],
      pitches: const <FushiPitchEntry>[
        FushiPitchEntry(
          dictName: 'P',
          pitchPositions: <int>[2],
          patterns: <String>['nakadaka'],
          transcriptions: <String>['/ta.be.ru/'],
        ),
      ],
    ),
  );
}

void main() {
  group('LookupJobScheduler（最后输入为准）', () {
    late List<String> started;
    late Map<String, Completer<String>> gates;
    late LookupJobScheduler<({String id, String? lane}), String> scheduler;

    setUp(() {
      started = <String>[];
      gates = <String, Completer<String>>{};
      scheduler = LookupJobScheduler<({String id, String? lane}), String>(
        run: (({String id, String? lane}) job) {
          started.add(job.id);
          return (gates[job.id] = Completer<String>()).future;
        },
        onDropped: (({String id, String? lane}) job) => 'dropped:${job.id}',
        laneOf: (({String id, String? lane}) job) => job.lane,
      );
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('同时只跑一个；新的先跑（LIFO），没有 lane 的旧请求不丢', () async {
      final Future<String> a = scheduler.submit((id: 'a', lane: null));
      final Future<String> b = scheduler.submit((id: 'b', lane: null));
      final Future<String> c = scheduler.submit((id: 'c', lane: null));
      expect(started, <String>['a']);
      expect(scheduler.queuedCount, 2);

      gates['a']!.complete('A');
      expect(await a, 'A');
      await settle();
      expect(started, <String>['a', 'c'], reason: '最新的 c 插到 b 前面');

      gates['c']!.complete('C');
      expect(await c, 'C');
      await settle();
      expect(started, <String>['a', 'c', 'b']);
      gates['b']!.complete('B');
      expect(await b, 'B', reason: '没声明 lane 的请求照样拿到自己的结果');
    });

    test('同 lane 未开始的旧请求被丢弃；在跑的不受影响；别的 lane 不受影响', () async {
      final Future<String> running = scheduler.submit((id: 'r', lane: 'hover'));
      final Future<String> stale = scheduler.submit((id: 's', lane: 'hover'));
      final Future<String> other = scheduler.submit((id: 'o', lane: 'more'));
      final Future<String> plain = scheduler.submit((id: 'p', lane: null));
      final Future<String> latest = scheduler.submit((id: 'l', lane: 'hover'));

      expect(await stale, 'dropped:s');
      expect(scheduler.queuedCount, 3);

      gates['r']!.complete('R');
      expect(await running, 'R', reason: '已经开始的不可中断，结果照常返回');
      await settle();
      expect(started.last, 'l');
      gates['l']!.complete('L');
      expect(await latest, 'L');
      await settle();
      gates['p']!.complete('P');
      expect(await plain, 'P');
      await settle();
      gates['o']!.complete('O');
      expect(await other, 'O');
      expect(started, isNot(contains('s')), reason: '被取代的请求从未执行');
    });

    test('任务出错：错误交给该调用方，队列继续', () async {
      final Future<String> bad = scheduler.submit((id: 'bad', lane: null));
      final Future<String> next = scheduler.submit((id: 'n', lane: null));
      gates['bad']!.completeError(StateError('boom'));
      await expectLater(bad, throwsStateError);
      await settle();
      gates['n']!.complete('N');
      expect(await next, 'N');
    });

    test('drain：丢弃未开始的，等在跑的跑完', () async {
      final Future<String> running = scheduler.submit((id: 'r', lane: null));
      final Future<String> queued = scheduler.submit((id: 'q', lane: null));
      bool drained = false;
      final Future<void> drain = scheduler.drain().then((_) => drained = true);
      expect(await queued, 'dropped:q');
      await settle();
      expect(drained, isFalse, reason: '在跑的任务还没回信（原生调用不可中断）');
      gates['r']!.complete('R');
      expect(await running, 'R');
      await drain;
      expect(drained, isTrue);
      expect(started, <String>['r']);
    });
  });

  group('FushiLookupFfiCache', () {
    test('按字节封顶淘汰最旧的；单条超预算不缓存也不挤别人', () {
      final FushiLookupFfiCache cache = FushiLookupFfiCache()..bindEngine(1);
      final List<FushiLookupResult> big = <FushiLookupResult>[
        _lookupResult(glossaryChars: 1000),
      ];
      final int size = estimateFushiLookupResultsBytes(big);
      final int budget = size * 2 + size ~/ 2;
      cache.put('a', big, maxBytes: budget);
      cache.put('b', big, maxBytes: budget);
      expect(cache.get('a'), isNotNull); // a 变成最新
      cache.put('c', big, maxBytes: budget);
      expect(cache.get('b'), isNull, reason: 'b 是最久没用的，被淘汰');
      expect(cache.get('a'), isNotNull);
      expect(cache.get('c'), isNotNull);
      expect(cache.bytes, lessThanOrEqualTo(budget));

      cache.put('huge', <FushiLookupResult>[
        _lookupResult(glossaryChars: 50000),
      ], maxBytes: budget);
      expect(cache.get('huge'), isNull);
      expect(cache.length, 2);
    });

    test('引擎实例代次变了整体失效（词典变更后缓存失效）', () {
      final FushiLookupFfiCache cache = FushiLookupFfiCache()..bindEngine(7);
      cache.put('k', <FushiLookupResult>[_lookupResult()], maxBytes: 1 << 20);
      cache.bindEngine(7);
      expect(cache.get('k'), isNotNull, reason: '同一引擎实例：命中');
      cache.bindEngine(8);
      expect(cache.get('k'), isNull, reason: '换了引擎实例：旧结果一条都不能用');
      expect(cache.bytes, 0);
    });

    test('estimateFushiLookupResultsBytes 按 UTF-16 每码元 2 字节计 glossary', () {
      final int small = estimateFushiLookupResultsBytes(<FushiLookupResult>[
        _lookupResult(glossaryChars: 0),
      ]);
      final int big = estimateFushiLookupResultsBytes(<FushiLookupResult>[
        _lookupResult(glossaryChars: 100000),
      ]);
      expect(big - small, 200000);
      expect(
        estimateFushiLookupResultsBytes(const <FushiLookupResult>[]),
        greaterThan(0),
      );
    });
  });

  group('buildFfiLookupCacheKey', () {
    test('短串保持旧格式 len:term/max', () {
      expect(buildFfiLookupCacheKey(term: '図書館', maxResults: 10), '3:図書館/10');
    });

    test('中文简繁回落开着时键尾带 /zh，关着时与旧格式逐字相同', () {
      expect(buildFfiLookupCacheKey(term: '这个', maxResults: 8), '2:这个/8');
      expect(
        buildFfiLookupCacheKey(
          term: '这个',
          maxResults: 8,
          chineseSimpToTrad: true,
        ),
        '2:这个/8/zh',
      );
    });

    test('只取扫描窗口：窗口外的余文不进键，代理对按一个码点计', () {
      final String head = '\u{2000B}' * 17;
      expect(
        buildFfiLookupCacheKey(term: '$head余文一', maxResults: 5),
        buildFfiLookupCacheKey(term: '$head別の余文', maxResults: 5),
      );
      expect(buildFfiLookupCacheKey(term: head, maxResults: 5), '34:$head/5');
      expect(
        buildFfiLookupCacheKey(term: '$head余', maxResults: 5),
        isNot(buildFfiLookupCacheKey(term: '$head余', maxResults: 6)),
      );
    });
  });

  group('buildLookupEntryExtra（每个词头只编码一次共用段）', () {
    test('与旧实现逐字节一致', () {
      final List<FushiLookupResult> samples = <FushiLookupResult>[
        _lookupResult(),
        _lookupResult(trace: const <FushiTransformGroup>[]),
        _lookupResult(
          matched: 'colour',
          deinflected: 'color',
          trace: const <FushiTransformGroup>[],
        ),
        _lookupResult(
          glossaries: const <FushiGlossaryEntry>[
            FushiGlossaryEntry(
              dictName: 'X',
              glossary: '[{"type":"structured-content"}]',
              definitionTags: '',
              termTags: 'P ★\n"q"',
            ),
            FushiGlossaryEntry(
              dictName: 'Y',
              glossary: 'plain',
              definitionTags: '\u0000 ',
              termTags: 'news',
            ),
          ],
        ),
      ];
      for (final FushiLookupResult r in samples) {
        for (final FushiGlossaryEntry g in r.term.glossaries) {
          expect(buildLookupEntryExtra(r, g), _referenceExtra(r, g));
        }
        final DictionarySearchResult built = buildResultFromLookup(
          searchTerm: r.matched,
          results: <FushiLookupResult>[r],
          maximumTerms: 10,
        );
        expect(
          built.entries.map((DictionaryEntry e) => e.extra).toList(),
          <String>[
            for (final FushiGlossaryEntry g in r.term.glossaries)
              _referenceExtra(r, g),
          ],
          reason: 'buildResultFromLookup 走的共用段路径与旧实现一致',
        );
      }
    });
  });

  test('TransformDescriptionCatalog.revision 随 apply / clear 推进', () {
    final int start = TransformDescriptionCatalog.revision;
    TransformDescriptionCatalog.apply(
      localeTag: 'zh-CN',
      translations: const <String, String>{'a': 'b'},
    );
    expect(TransformDescriptionCatalog.revision, start + 1);
    expect(TransformDescriptionCatalog.translations, <String, String>{
      'a': 'b',
    });
    TransformDescriptionCatalog.clear();
    expect(TransformDescriptionCatalog.revision, start + 2);
  });
}
