import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

/// 导入对话框「逐步进度」基础设施的共享 mixin。
///
/// [BookImportDialog] 与 [AudiobookImportDialog] 各自重复同一套进度状态机：
/// `importing` 布尔 + 进度比例/文案两个 [ValueNotifier] + `reportProgress`
/// 写入器 + dispose 释放 + build 里的 `LinearProgressIndicator` 进度块。把它
/// 收敛到一处，消除手抄。**零行为变化**：字段语义、`reportProgress` 签名、进度块
/// 像素结构与抽取前逐字等价。
///
/// 注意：video 导入对话框是不同形态（`_busy` 布尔 + `CircularProgressIndicator`，
/// 无逐步进度），刻意**不**接入本 mixin，避免给它凭空造出不存在的行为。
mixin ImportDialogProgressMixin<T extends StatefulWidget> on State<T> {
  /// 是否正在导入。宿主在 `_doImport` 起止处 `setState(() => importing = …)`，
  /// 用于禁用确认按钮 / 切换 spinner / 显隐进度块。
  bool importing = false;

  /// 进度比例（0..1）。`null` 值喂给 [LinearProgressIndicator] 时显示不确定动画。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  /// 进度文案（当前步骤名 / 正在复制的文件名等）。
  final ValueNotifier<String> progressMsg = ValueNotifier<String>('');

  /// 一次写入进度比例与文案（导入各阶段调用）。
  void reportProgress(double value, String msg) {
    progress.value = value;
    progressMsg.value = msg;
  }

  @override
  void dispose() {
    progress.dispose();
    progressMsg.dispose();
    super.dispose();
  }

  /// 导入进行中时渲染的进度块组件序列：间距 + 进度条 + 间距 + 文案。
  ///
  /// 返回的是 **待 spread 进父级 `Column.children` 的 widget 列表**（不是包一层
  /// `Column`），所以宿主用 `if (importing) ...buildProgressSection(context, tokens)`
  /// 替换原内联块时，渲染树与抽取前逐字等价——不引入任何额外的布局层。
  List<Widget> buildProgressSection(
    BuildContext context,
    HibikiDesignTokens tokens,
  ) {
    return <Widget>[
      SizedBox(height: tokens.spacing.card),
      ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, __) => LinearProgressIndicator(value: value),
      ),
      SizedBox(height: tokens.spacing.gap / 2),
      ValueListenableBuilder<String>(
        valueListenable: progressMsg,
        builder: (_, msg, __) => Text(
          msg,
          style: tokens.type.metadata,
        ),
      ),
    ];
  }
}
