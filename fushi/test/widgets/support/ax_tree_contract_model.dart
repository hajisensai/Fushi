// 测试侧接线：截获发往引擎的语义更新，逐帧交给生产代码里的
// [AxTreeContractModel]（`lib/src/utils/misc/semantics_ax_tree_contract.dart`，
// 那里写了引擎 `AccessibilityBridge` + `ui::AXTree` 的两步契约与它和 BUG-4073 /
// BUG-2345 / BUG-2337 / BUG-2839 崩点的关系）。违约的帧让测试失败，并打出整帧内容。
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/semantics_ax_tree_contract.dart';

/// 截获发往引擎的语义更新的测试 binding。
class SemanticsUpdateSpyBinding extends AutomatedTestWidgetsFlutterBinding {
  /// 自上次 [AxTreeContractChecker.commitFrame] 以来 build 出的帧。
  final List<Map<int, AxSentNode>> frames = <Map<int, AxSentNode>>[];

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      AxRecordingSemanticsUpdateBuilder(
        super.createSemanticsUpdateBuilder(),
        frames.add,
      );
}

/// 把截到的帧按顺序喂给契约模型，任一帧违约就让测试失败。
class AxTreeContractChecker {
  AxTreeContractChecker(this.binding) {
    binding.frames.clear();
  }

  final SemanticsUpdateSpyBinding binding;
  final AxTreeContractModel model = AxTreeContractModel();

  /// 已核对的非空帧数。
  int checkedFrames = 0;

  bool hasLabel(String text) => model.hasLabel(text);

  void commitFrame(String step) {
    final List<Map<int, AxSentNode>> frames = List<Map<int, AxSentNode>>.of(
      binding.frames,
    );
    binding.frames.clear();
    for (final Map<int, AxSentNode> sent in frames) {
      if (sent.isEmpty) {
        continue;
      }
      checkedFrames++;
      final List<String> violations = model.commit(
        sent,
        checkHitTestTree: true,
      );
      if (violations.isEmpty) {
        continue;
      }
      final StringBuffer dump = StringBuffer(
        '$step: frame violates the desktop AXTree contract:\n  '
        '${violations.join('\n  ')}\n  frame sent:',
      );
      for (final MapEntry<int, AxSentNode> n in sent.entries) {
        dump.write(
          '\n    ${n.key} "${n.value.label}" '
          'traversal=${n.value.traversal} hitTest=${n.value.hitTest}',
        );
      }
      fail(dump.toString());
    }
  }
}
