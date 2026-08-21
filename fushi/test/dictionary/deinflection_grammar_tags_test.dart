import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 查词弹窗的**语法说明**（词形变化链上每一层的语法解释）。
///
/// 数据早就全在包里：`assets/transforms/<lang>.json` 每个 transform 都带 Yomitan
/// 的语法说明，`deinflector.cpp` 解析进 `TransformGroup{name, description}`，
/// `lookup.cpp` 把整条 trace 挂在每个 LookupResult 上，FFI 也把 name+description
/// 都送到了 Dart。断的是最后一米：四处拼弹窗 JSON 的代码各自把 trace 丢掉，
/// 换成一条现编的 `matched → deinflected` 且 `description` 恒为空串。
///
/// 这组测试锁住修好之后的语义，外加一条源码守卫防止那四份拷贝重新长回来。
void main() {
  FushiTermResult term() => FushiTermResult(
        expression: '当たる',
        reading: 'あたる',
        rules: '',
        glossaries: [
          FushiGlossaryEntry(
            dictName: 'JMdict',
            glossary: jsonEncode(['to hit']),
            definitionTags: '',
            termTags: '',
          ),
        ],
        frequencies: [],
        pitches: [],
      );

  // 引擎压栈顺序 = 剥离顺序：`当たっていた` 先剥最外层的 -た，再剥 -いる，
  // 最后剥 -て。所以 trace 是 [-た, -いる, -て]。
  const List<FushiTransformGroup> ateiruTrace = [
    FushiTransformGroup(name: '-た', description: 'Indicates the past.'),
    FushiTransformGroup(name: '-いる', description: 'Indicates continuation.'),
    FushiTransformGroup(name: '-て', description: 'て-form.'),
  ];

  FushiLookupResult lookup({
    required String matched,
    required String deinflected,
    List<FushiTransformGroup> trace = const [],
  }) =>
      FushiLookupResult(
        matched: matched,
        deinflected: deinflected,
        trace: trace,
        preprocessorSteps: 0,
        term: term(),
      );

  group('buildDeinflectionTags', () {
    test('trace 反转成接续顺序，语法说明逐条带上', () {
      // 用户看到的是「从词典形出发依次接了哪些变形」，与 Yomitan 的
      // `-て « -いる « -た` 同序——正是引擎压栈顺序的反转。
      final List<DeinflectionTag> tags = buildDeinflectionTags(
        matched: '当たっていた',
        deinflected: '当たる',
        trace: ateiruTrace,
      );

      expect(tags.map((t) => t.name).toList(), ['-て', '-いる', '-た']);
      expect(tags.map((t) => t.description).toList(), [
        'て-form.',
        'Indicates continuation.',
        'Indicates the past.',
      ]);
    });

    test('trace 非空时不再生成 "matched → deinflected" 那条现编标签', () {
      final List<DeinflectionTag> tags = buildDeinflectionTags(
        matched: '当たっていた',
        deinflected: '当たる',
        trace: ateiruTrace,
      );

      expect(
        tags.any((t) => t.name.contains('→')),
        isFalse,
        reason: '有真实变形链时不该再退回那条没有语法说明的合并标签',
      );
    });

    test('trace 为空但 matched≠deinflected → 回落成单条，说明为空', () {
      // 这是 lookup.cpp 的**文本变体归一**（colour→color 一类）：它不经过任何
      // 变形规则，所以没有 trace 也没有语法说明。回落分支删掉的话，这类查询会
      // 完全不提示词形变化——属于行为回退，不是简化。
      final List<DeinflectionTag> tags = buildDeinflectionTags(
        matched: 'colour',
        deinflected: 'color',
        trace: const [],
      );

      expect(tags.length, 1);
      expect(tags.single.name, 'colour → color');
      expect(tags.single.description, isEmpty);
    });

    test('原形直查（matched == deinflected）→ 空，不生成自指标签', () {
      expect(
        buildDeinflectionTags(
          matched: '当たる',
          deinflected: '当たる',
          trace: const [],
        ),
        isEmpty,
      );
    });

    test('引擎未回填 deinflected（空串）→ 空，不生成「x → 」残缺标签', () {
      expect(
        buildDeinflectionTags(
          matched: '当たっていた',
          deinflected: '',
          trace: const [],
        ),
        isEmpty,
      );
    });
  });

  group('extra 往返', () {
    test('buildLookupEntryExtra 写出的标签能被 deinflectionTagsFromExtra 原样读回', () {
      // 走 extra 的两条路径（原生弹窗、buildLookupEntriesJson）此前只能看到
      // matched/deinflected，语法说明就是断在这里的。
      final String extra = buildLookupEntryExtra(
        lookup(
          matched: '当たっていた',
          deinflected: '当たる',
          trace: ateiruTrace,
        ),
        term().glossaries.single,
      );

      final List<DeinflectionTag> tags = deinflectionTagsFromExtra(
        jsonDecode(extra) as Map<String, dynamic>,
      );

      expect(tags.map((t) => t.name).toList(), ['-て', '-いる', '-た']);
      expect(tags.first.description, 'て-form.');
    });

    test('老 extra（没有 deinflectionTrace 键）仍按 matched/deinflected 回落', () {
      final List<DeinflectionTag> tags = deinflectionTagsFromExtra(
        <String, dynamic>{'matched': 'colour', 'deinflected': 'color'},
      );

      expect(tags.single.name, 'colour → color');
      expect(tags.single.description, isEmpty);
    });

    test('老 extra 且 matched == deinflected → 空', () {
      expect(
        deinflectionTagsFromExtra(
          <String, dynamic>{'matched': '当たる', 'deinflected': '当たる'},
        ),
        isEmpty,
      );
    });
  });

  group('两条弹窗路径都送出真实变形链', () {
    test('buildPopupJsonFromLookup（主路径）', () {
      final List decoded = jsonDecode(buildPopupJsonFromLookup(
        results: [
          lookup(
            matched: '当たっていた',
            deinflected: '当たる',
            trace: ateiruTrace,
          )
        ],
        maximumTerms: 100,
        hiddenDictionaries: const <String>{},
      )) as List;

      expect((decoded.single as Map<String, dynamic>)['deinflectionTrace'], [
        {'name': '-て', 'description': 'て-form.'},
        {'name': '-いる', 'description': 'Indicates continuation.'},
        {'name': '-た', 'description': 'Indicates the past.'},
      ]);
    });

    test('buildLookupEntriesJson（extra 路径）与主路径逐字段一致', () {
      final List<FushiLookupResult> results = [
        lookup(
          matched: '当たっていた',
          deinflected: '当たる',
          trace: ateiruTrace,
        )
      ];

      final List viaLookup = jsonDecode(buildPopupJsonFromLookup(
        results: results,
        maximumTerms: 100,
        hiddenDictionaries: const <String>{},
      )) as List;

      final List viaExtra = jsonDecode(
        DictionaryPopupWebViewState.buildLookupEntriesJson(
          buildResultFromLookup(
            searchTerm: '当たっていた',
            results: results,
            maximumTerms: 100,
          ),
        ),
      ) as List;

      expect(
        (viaExtra.single as Map<String, dynamic>)['deinflectionTrace'],
        (viaLookup.single as Map<String, dynamic>)['deinflectionTrace'],
      );
    });
  });

  group('源码守卫：变形标签只有一处生成', () {
    final String root = _repoRoot();

    test('Dart 侧：只有 buildDeinflectionTags 拼那条 "matched → deinflected"', () {
      // 不变式：回落标签的拼接字面量（下方 needle）只允许出现在 language.dart 的
      // buildDeinflectionTags 函数体里。消费点各自再拼一遍，正是语法说明断掉四次
      // 的原因——它们拼出来的 description 永远是空串。
      //
      // 断言字面量（守卫变异测试用，勿删）：空格 + U+2192 + 空格
      const String needle = ' → ';

      final String languagePath = p.join(root, 'packages', 'fushi_dictionary',
          'lib', 'src', 'language', 'language.dart');
      final String languageSrc = maskCommentsAndScriptLines(
        File(languagePath).readAsStringSync(),
      );

      final String? body =
          topLevelFunctionBody(languageSrc, 'buildDeinflectionTags');
      expect(body, isNotNull,
          reason: 'buildDeinflectionTags 必须是 language.dart 的顶层函数');
      expect(body!.contains(needle), isTrue,
          reason: '回落分支必须留在 buildDeinflectionTags 内（不能删）');

      // 整个 language.dart 里该字面量只此一处。
      expect(
        needle.allMatches(languageSrc).length,
        1,
        reason: 'language.dart 里只允许 buildDeinflectionTags 拼这条回落标签',
      );

      // 三个消费点一处都不许拼。
      final List<String> consumers = [
        p.join(root, 'fushi', 'lib', 'src', 'pages', 'implementations',
            'dictionary_popup_webview.dart'),
        p.join(root, 'fushi', 'lib', 'src', 'pages', 'implementations',
            'dictionary_popup_native.dart'),
      ];
      for (final String path in consumers) {
        final String src =
            maskCommentsAndScriptLines(File(path).readAsStringSync());
        expect(src.contains(needle), isFalse,
            reason: '${p.basename(path)} 必须走 buildDeinflectionTags，'
                '不能自己拼变形标签（自己拼出来的 description 恒为空串）');
      }
    });

    test('C++ 侧：popup_json.cpp 只在 write_deinflection_tags 里拼', () {
      // 断言字面量（守卫变异测试用，勿删）： \xe2\x86\x92  即 UTF-8 的「→」
      const String arrow = r'\xe2\x86\x92';

      final String path = p.join(
          root, 'native', 'fushidicts', 'fushidicts_src', 'popup_json.cpp');
      final String src = File(path).readAsStringSync();

      expect(
        arrow.allMatches(src).length,
        1,
        reason: 'popup_json.cpp 里「→」只允许出现在 write_deinflection_tags 的'
            '回落分支——多一处就说明有人又在别处现编变形标签了',
      );
      expect(
        src.contains('write_deinflection_tags(os, gd.matched, gd.deinflected'),
        isTrue,
        reason: 'deinflectionTrace 必须由 write_deinflection_tags 写出，'
            '它才是与 Dart 侧 buildDeinflectionTags 对齐的那一份',
      );
      expect(
        src.contains('gd.trace = r.trace') ||
            src.contains('gd.trace') && src.contains('it->second.trace'),
        isTrue,
        reason: '分组时必须把真实 trace 一起带上，否则永远只剩回落分支',
      );
    });
  });
}

String _repoRoot() {
  Directory dir = Directory.current;
  while (!File(p.join(dir.path, 'native', 'fushidicts', 'CMakeLists.txt'))
      .existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}
