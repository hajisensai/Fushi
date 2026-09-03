import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-2089：`AnkiMiningPayload` 走**两条编码不同的线**，`fromJson` 必须对两条都成立。
///
/// 1. **保类型 JSON**——浏览器扩展 / 远端 `/api/mine`，布尔就是布尔。
/// 2. **全字符串**——应用内 WebView 桥：`dictionary_popup_webview.dart` 与
///    `overlay_bridge_handlers.dart` 都逐值 `.toString()` 拍平成 `Map<String, String>`
///    （下游 `ImmersionMiningRequest.fields` / `miningHandler(fields:)` / 互联转发
///    全是 `Map<String, String>`）。
///
/// 新增的 `glossarySelectionHighlighted` 用了裸 `as bool?`，于是第 2 条线上
/// **每一次应用内制卡都抛** `type 'String' is not a subtype of type 'bool?'`，
/// 用户看到「导出卡片失败: Invalid card data (payload parse failed)」。
void main() {
  /// 复刻两条桥的拍平方式——判据必须跟着真实生产代码走，不是自己想一个。
  Map<String, dynamic> throughInAppBridge(Map<String, Object?> fromJs) {
    final Map<String, String> flattened = Map<String, String>.from(
      fromJs.map((String k, Object? v) => MapEntry(k, v?.toString() ?? '')),
    );
    return Map<String, dynamic>.from(
        jsonDecode(jsonEncode(flattened)) as Map);
  }

  group('BUG-2089：制卡 payload 的两条线都必须能解析', () {
    test('应用内桥（全字符串）：布尔字段两个取值都不炸且值正确', () {
      for (final bool value in <bool>[true, false]) {
        final AnkiMiningPayload p = AnkiMiningPayload.fromJson(
          throughInAppBridge(<String, Object?>{
            'expression': '三文芝居',
            'reading': 'さんもんしばい',
            'glossarySelectionHighlighted': value,
          }),
        );
        expect(p.expression, '三文芝居');
        expect(p.glossarySelectionHighlighted, value,
            reason: '桥上是 "${value.toString()}"，解析后必须还原成 $value');
      }
    });

    test('保类型 JSON（扩展/远端）：原生布尔照旧', () {
      final AnkiMiningPayload t = AnkiMiningPayload.fromJson(
          jsonDecode('{"expression":"語","glossarySelectionHighlighted":true}')
              as Map<String, dynamic>);
      expect(t.glossarySelectionHighlighted, isTrue);
      final AnkiMiningPayload f = AnkiMiningPayload.fromJson(
          jsonDecode('{"expression":"語","glossarySelectionHighlighted":false}')
              as Map<String, dynamic>);
      expect(f.glossarySelectionHighlighted, isFalse);
    });

    test('字段缺失 / 空串 / 垃圾值一律 false，不做「非空即真」的宽松解析', () {
      expect(
          AnkiMiningPayload.fromJson(<String, dynamic>{'expression': 'x'})
              .glossarySelectionHighlighted,
          isFalse);
      for (final String junk in <String>['', 'TRUE', 'yes', '1', 'null']) {
        expect(
            AnkiMiningPayload.fromJson(throughInAppBridge(<String, Object?>{
              'glossarySelectionHighlighted': junk,
            })).glossarySelectionHighlighted,
            isFalse,
            reason: '"$junk" 不是这两条线会产生的形态，必须判 false 而不是 true');
      }
    });

    /// 结构性防复发：只修一个字段是补丁，下一个往 payload 加非 String 字段的人
    /// 会原样再踩一次。`fromJson` 里禁止对非 String 字段用裸 `as` 强转——
    /// 全字符串那条线上它们必然抛。
    test('fromJson 里不得再出现裸的非 String 类型强转', () {
      final File f = File('lib/src/anki_models.dart');
      expect(f.existsSync(), isTrue, reason: '判据锚点找不到源文件');
      final String src = f.readAsStringSync();
      const String head =
          'factory AnkiMiningPayload.fromJson(Map<String, dynamic> json) {';
      final int start = src.indexOf(head);
      expect(start, greaterThan(-1), reason: 'fromJson 签名变了，判据已失效');
      final int end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start), reason: '取不到 fromJson 函数体');
      final String body = src.substring(start, end);
      // 自校验：窗口没塌成空壳（下面的否定断言在空串上恒真）。
      expect(body, contains('expression:'),
          reason: 'fromJson 函数体窗口切歪了，判据已失效');
      expect(body, contains('dictionaryMedia'),
          reason: 'fromJson 函数体被截短了，判据覆盖不全');

      for (final String banned in <String>[
        'as bool?',
        'as bool',
        'as int?',
        'as int',
        'as num?',
        'as num',
        'as double?',
        'as double',
      ]) {
        expect(body.contains(banned), isFalse,
            reason: '$banned 在「全字符串」那条线上必抛 —— '
                '改用与 _boolFromPayloadWire 同源的两分支解析');
      }
    });
  });
}
