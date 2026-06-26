// 全局查词「有序弹窗栈」纯逻辑（TODO-867 阶段3 地基 P3a）。
//
// 移植自 hoshi Android 的 `LookupPopupStack.kt`（有序 List 模型 + 截断式关闭）。
// 本文件**只**包含栈的纯函数 + 不可变数据结构：无 Riverpod / 无 IO / 无平台依赖，
// 全部操作输入栈 + 参数 -> 返回新栈，绝不原地修改入参。后续 P3b（popup.js
// renderStack）/ P3c（C++ 窗口 + 鼠标钩子）会消费这里产出的 [GlobalLookupStack]。
//
// 栈语义（对齐 LookupPopupStack.kt）：
//   - index 0 是根弹窗，越靠后越深（子窗）。
//   - 关 index i 的子窗 = 把列表截断到 i（含 i），即 sublist(0, i + 1)。
//   - 关闭某弹窗（dismiss）：根（index 0）-> 清空整栈；否则回退到其父级并给父级
//     发一次「清选区高亮」信号（clearSelectionSignal 单调 +1）。
//   - 父窗滚动 / 重选词 -> 砍掉其所有子窗并给父级发清选区信号。
//   - 查无结果（结果为空）-> 不压入空 frame，返回原栈不变。
//
// 关于 id：移植期 hoshi 用 `UUID.randomUUID()`，但测试环境禁用随机/时钟类不可测。
// 因此本模块**不在纯函数内部产生任何随机/时钟 id**——id 一律由调用方作为参数传入
// （生产侧可用单调计数器或 UUID，测试侧传确定字符串），保持纯函数完全可测。

import 'package:flutter/foundation.dart';

/// 栈中单个查词弹窗层的不可变快照。
///
/// 只保留驱动栈逻辑 + 后续渲染所需的最小字段；几何（屏幕坐标 / 弹窗尺寸）留给
/// P3c，本阶段不引入，避免过度设计。
@immutable
class GlobalLookupFrame {
  const GlobalLookupFrame({
    required this.id,
    required this.query,
    required this.parentIndex,
    this.resultCount = 0,
    this.clearSelectionSignal = 0,
  });

  /// 稳定标识。由调用方传入（不在纯函数内部生成随机/时钟值，保证可测）。
  final String id;

  /// 该层查词的文本。
  final String query;

  /// 父层在栈中的 index；根层为 -1（无父）。
  final int parentIndex;

  /// 该层查词命中的结果条数。0 代表查无结果——调用方据此决定不入栈
  /// （见 [pushLookupFrame]）。仅作占位/诊断用途，栈逻辑不依赖其具体数值。
  final int resultCount;

  /// 「清除选区高亮」单调信号。每当本层需要让其底层 WebView 清掉选区高亮时 +1；
  /// 下游对比新旧值即可触发一次清除（对齐 hoshi `clearSelectionSignal`）。
  final int clearSelectionSignal;

  /// 返回一个字段被覆盖的副本（不可变更新）。
  GlobalLookupFrame copyWith({
    String? id,
    String? query,
    int? parentIndex,
    int? resultCount,
    int? clearSelectionSignal,
  }) {
    return GlobalLookupFrame(
      id: id ?? this.id,
      query: query ?? this.query,
      parentIndex: parentIndex ?? this.parentIndex,
      resultCount: resultCount ?? this.resultCount,
      clearSelectionSignal: clearSelectionSignal ?? this.clearSelectionSignal,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GlobalLookupFrame &&
        other.id == id &&
        other.query == query &&
        other.parentIndex == parentIndex &&
        other.resultCount == resultCount &&
        other.clearSelectionSignal == clearSelectionSignal;
  }

  @override
  int get hashCode =>
      Object.hash(id, query, parentIndex, resultCount, clearSelectionSignal);

  @override
  String toString() {
    return 'GlobalLookupFrame(id: $id, query: "$query", parentIndex: '
        '$parentIndex, resultCount: $resultCount, clearSelectionSignal: '
        '$clearSelectionSignal)';
  }
}

/// 不可变的查词弹窗栈：有序 frame 列表（index 0 是根，越靠后越深）。
///
/// 所有变换返回新的 [GlobalLookupStack]，内部 [frames] 是不可修改视图，绝不原地改。
@immutable
class GlobalLookupStack {
  /// 用一份 frame 列表构造栈；内部存为不可修改副本，防止外部别名后篡改。
  GlobalLookupStack(List<GlobalLookupFrame> frames)
      : frames = List<GlobalLookupFrame>.unmodifiable(frames);

  /// 空栈常量入口。
  static final GlobalLookupStack empty =
      GlobalLookupStack(const <GlobalLookupFrame>[]);

  /// 栈中各层，index 0 为根，末尾为最深子窗。不可修改。
  final List<GlobalLookupFrame> frames;

  /// 当前深度。
  int get length => frames.length;

  /// 是否为空栈。
  bool get isEmpty => frames.isEmpty;

  /// 是否非空。
  bool get isNotEmpty => frames.isNotEmpty;

  /// 栈顶（最深）frame；空栈返回 null。
  GlobalLookupFrame? get topFrame => frames.isEmpty ? null : frames.last;

  /// 栈顶 frame 的 id；空栈返回 null。
  String? get topFrameId => frames.isEmpty ? null : frames.last.id;

  @override
  bool operator ==(Object other) {
    if (other is! GlobalLookupStack) {
      return false;
    }
    if (other.frames.length != frames.length) {
      return false;
    }
    for (int i = 0; i < frames.length; i++) {
      if (other.frames[i] != frames[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(frames);

  @override
  String toString() => 'GlobalLookupStack(${frames.length}: $frames)';
}

/// 把 [frame] 压入 [stack] 顶部，返回新栈。
///
/// 对齐 hoshi `createLookupPopupItem`：当 [frame] 查无结果（`resultCount <= 0`）时
/// **不入栈**，原样返回 [stack]（不压空层、不弹空窗）。
GlobalLookupStack pushLookupFrame(
  GlobalLookupStack stack,
  GlobalLookupFrame frame,
) {
  if (frame.resultCount <= 0) {
    return stack;
  }
  return GlobalLookupStack(<GlobalLookupFrame>[...stack.frames, frame]);
}

/// 关掉 `parentIndex` 之后的所有子窗，保留到 `parentIndex`（含）。
///
/// 对齐 hoshi `closeChildPopups(popups, parentIndex) = popups.take(parentIndex+1)`。
/// `parentIndex` 越界时安全 clamp：负数 -> 清空整栈（保留 0 层）；>= 末尾 ->
/// 原样返回（无子窗可关）。
GlobalLookupStack closeChildPopups(
  GlobalLookupStack stack,
  int parentIndex,
) {
  if (parentIndex < 0) {
    return GlobalLookupStack.empty;
  }
  if (parentIndex >= stack.frames.length - 1) {
    return stack;
  }
  return GlobalLookupStack(stack.frames.sublist(0, parentIndex + 1));
}

/// 关掉 `parentIndex` 子窗并给该父级发一次清选区信号。
///
/// 对齐 hoshi `closeChildPopupsAndClearSelection`：父级 index 越界则原样返回；
/// 否则截断到父级，并把父级的 [GlobalLookupFrame.clearSelectionSignal] +1。
/// 用于「点弹窗外空白处」——关子窗 + 清当前层选区高亮。
GlobalLookupStack closeChildPopupsAndClearSelection(
  GlobalLookupStack stack,
  int parentIndex,
) {
  if (parentIndex < 0 || parentIndex >= stack.frames.length) {
    return stack;
  }
  final List<GlobalLookupFrame> truncated =
      stack.frames.sublist(0, parentIndex + 1);
  return GlobalLookupStack(
    _bumpClearSignalAt(truncated, parentIndex),
  );
}

/// 关闭 `index` 处的弹窗及其所有子窗。
///
/// 对齐 hoshi `dismissPopupAt`：
///   - `index == 0`（关根）-> 清空整栈。
///   - `index > 0` -> 回退到父级（截断到 `index - 1`，含父级），并给父级发一次
///     清选区信号。
/// `index` 越界（负数或 >= 长度）安全处理：负数视作关根（清空）；过大视作无操作。
GlobalLookupStack dismissPopupAt(
  GlobalLookupStack stack,
  int index,
) {
  if (index <= 0) {
    return GlobalLookupStack.empty;
  }
  if (index >= stack.frames.length) {
    return stack;
  }
  final int parentIndex = index - 1;
  final List<GlobalLookupFrame> truncated =
      stack.frames.sublist(0, parentIndex + 1);
  return GlobalLookupStack(
    _bumpClearSignalAt(truncated, parentIndex),
  );
}

/// 父窗滚动 / 重选词后，砍掉其所有子窗并给父级发清选区信号。
///
/// 对齐 hoshi `closeChildPopupsForScrolledParent`：若 `parentIndex` 已是末层
/// （无子窗），**原样返回同一栈对象**（恒等，不重建、不 bump 信号）；否则截断到
/// 父级并 bump 其清选区信号。
GlobalLookupStack closeChildPopupsForScrolledParent(
  GlobalLookupStack stack,
  int parentIndex,
) {
  if (parentIndex < 0) {
    return stack;
  }
  if (parentIndex >= stack.frames.length - 1) {
    // 已是末层（含越界过大），无子窗可砍 -> 恒等返回。
    return stack;
  }
  final List<GlobalLookupFrame> truncated =
      stack.frames.sublist(0, parentIndex + 1);
  return GlobalLookupStack(
    _bumpClearSignalAt(truncated, parentIndex),
  );
}

/// 把列表里 `targetIndex` 处 frame 的 clearSelectionSignal +1，返回新列表。
List<GlobalLookupFrame> _bumpClearSignalAt(
  List<GlobalLookupFrame> frames,
  int targetIndex,
) {
  final List<GlobalLookupFrame> next =
      List<GlobalLookupFrame>.from(frames, growable: false);
  if (targetIndex >= 0 && targetIndex < next.length) {
    final GlobalLookupFrame parent = next[targetIndex];
    next[targetIndex] = parent.copyWith(
      clearSelectionSignal: parent.clearSelectionSignal + 1,
    );
  }
  return next;
}
