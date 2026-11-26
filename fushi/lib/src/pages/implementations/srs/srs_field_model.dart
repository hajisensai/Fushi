/// 字段编辑器的值模型，从 `srs_field_editors.dart` 下沉出来的叶子（那边原样再导出）：字段 AI 入口
/// （`srs_field_ai_action.dart`）只需要它，不必 import 整套编辑器（编辑器读 AppModel，在大 import 环里）。
library;

import 'package:flutter/foundation.dart' show ChangeNotifier;

/// 一个字段的当前值。编辑器改值走 [edit]；页面整体换值（重读笔记、连续添加后清空、
/// 冲突裁决）走 [reset]，编辑器据 [generation] 重建内部状态。
class SrsFieldModel extends ChangeNotifier {
  SrsFieldModel(this._value);

  String _value;
  int _generation = 0;

  String get value => _value;

  /// [reset] 的次数。
  int get generation => _generation;

  /// 编辑器改值。
  void edit(String value) {
    if (value == _value) return;
    _value = value;
    notifyListeners();
  }

  /// 外部整体换值（编辑器丢弃自身状态，按新值重新判类型）。
  void reset(String value) {
    _value = value;
    _generation++;
    notifyListeners();
  }
}
