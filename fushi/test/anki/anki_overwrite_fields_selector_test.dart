import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/anki/anki_overwrite_fields_selector.dart';

/// 反馈 nWWjBp3Clo：覆写对话框「覆写哪些字段」的勾选规则。
void main() {
  const List<String> fields = <String>['Expression', 'Sentence', 'Picture'];

  group('toggleOverwriteField', () {
    test('从「全部字段」取消勾一个 → 其余字段', () {
      final OverwriteFieldToggle r = toggleOverwriteField(
        allFields: fields,
        selection: null,
        field: 'Expression',
        checked: false,
      );
      expect(r.rejectedEmpty, isFalse);
      expect(r.selection, <String>{'Sentence', 'Picture'});
    });

    test('勾满全部字段 → 收回 null（全部字段）', () {
      final OverwriteFieldToggle r = toggleOverwriteField(
        allFields: fields,
        selection: <String>{'Sentence', 'Picture'},
        field: 'Expression',
        checked: true,
      );
      expect(r.rejectedEmpty, isFalse);
      expect(r.selection, isNull);
    });

    test('取消勾最后一个 → 拒绝，选择原样', () {
      final OverwriteFieldToggle r = toggleOverwriteField(
        allFields: fields,
        selection: <String>{'Sentence'},
        field: 'Sentence',
        checked: false,
      );
      expect(r.rejectedEmpty, isTrue);
      expect(r.selection, <String>{'Sentence'});
    });
  });

  group('effectiveOverwriteSelection', () {
    test('null 原样 = 全部字段', () {
      expect(
        effectiveOverwriteSelection(allFields: fields, stored: null),
        isNull,
      );
    });

    test('卡上没有的旧字段名不算数（与后端只点名卡上有的字段同口径）', () {
      expect(
        effectiveOverwriteSelection(
          allFields: fields,
          stored: <String>{'Sentence', 'OldName'},
        ),
        <String>{'Sentence'},
      );
      expect(
        effectiveOverwriteSelection(
          allFields: fields,
          stored: <String>{'OldName'},
        ),
        isEmpty,
      );
    });
  });
}
