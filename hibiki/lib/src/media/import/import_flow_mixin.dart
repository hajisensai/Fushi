import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';

/// 导入对话框共享的「导入流程」mixin：逐步进度基础设施 + [runImport] 执行模板。
///
/// 书/有声书/视频三个导入对话框各自重复同一套流程外壳：`importing` 布尔 +
/// 进度比例/文案两个 [ValueNotifier] + `reportProgress` 写入器 + dispose 释放 +
/// build 里的进度块，以及「try/catch/finally + [ErrorLogService] 落日志 + 失败
/// toast + busy 复位」的导入执行骨架（审计 §1-K）。把它收敛到一处，消除手抄。
/// **零行为变化**：字段语义、`reportProgress` 签名、进度块像素结构与抽取前逐字等价。
///
/// 进度展示两种形态并存：book/audiobook 用 [buildProgressSection]（LinearProgress
/// + 逐步文案）+ [buildImportAction]；video 无逐步进度，仅用 `importing` 驱动自己
/// 的 `CircularProgressIndicator`——mixin 的进度 notifier 对它只是未使用字段，
/// 不给它凭空造出不存在的行为。
mixin ImportFlowMixin<T extends StatefulWidget> on State<T> {
  /// 是否正在导入。[runImport] 起止处自动 `setState(() => importing = …)`，
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

  /// 导入执行模板（BUG-1117 的「导入异常静默逃逸 async zone」模式结构化）：
  ///
  /// 1. 起始 `setState(() => importing = true)`（禁用按钮 / 亮 spinner）；
  /// 2. `await action()`——**成功路径的 toast 与 `Navigator.pop(结果)` 由
  ///    [action] 自己做**（各对话框 pop 语义不同：book 回 bool、video 回 bookUid）；
  /// 3. 失败被捕获（绝不逃逸 zone）：[ErrorLogService] 以 [logTag] 为源落日志 +
  ///    `debugPrint`（[debugMessage] 可定制，默认 `'$logTag failed: $e'`）+ toast
  ///    `t.srt_import_error: $e`——**不 pop**，对话框留在原地供用户改参重试；
  /// 4. finally `setState(() => importing = false)` 复位（mounted 门控）。
  ///
  /// [isCancelled] / [onCancelled]：用户主动取消类异常（如同名书弹窗选「否」）
  /// 不算错误——命中时不落日志、不 toast，交给 [onCancelled] 做取消提示与 pop。
  Future<void> runImport({
    required String logTag,
    required Future<void> Function() action,
    String Function(Object error)? debugMessage,
    bool Function(Object error)? isCancelled,
    VoidCallback? onCancelled,
  }) async {
    setState(() => importing = true);
    try {
      await action();
    } catch (e, stack) {
      if (isCancelled != null && isCancelled(e)) {
        onCancelled?.call();
      } else {
        ErrorLogService.instance.log(logTag, e, stack);
        debugPrint(
          debugMessage != null ? debugMessage(e) : '$logTag failed: $e',
        );
        if (mounted) {
          HibikiToast.show(
            msg: '${t.srt_import_error}: $e',
            severity: ToastSeverity.error,
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => importing = false);
      }
    }
  }

  /// 「导入」确认按钮：导入中禁用并渲 spinner + 文案，否则渲 [t.dialog_import]。
  /// 两个导入对话框逐字相同的 action 收敛到此；Enter/默认键语义由
  /// `adaptiveDialogAction(isDefaultAction: true)` 原样保留，焦点行为不变。
  Widget buildImportAction(
    BuildContext context, {
    required VoidCallback onImport,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return adaptiveDialogAction(
      context: context,
      isDefaultAction: true,
      onPressed: importing ? null : onImport,
      child: importing
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: tokens.spacing.gap * 2,
                  height: tokens.spacing.gap * 2,
                  child: adaptiveIndicator(
                    context: context,
                    strokeWidth: 2,
                    color: tokens.surfaces.primary,
                  ),
                ),
                SizedBox(width: tokens.spacing.gap),
                Text(t.dialog_importing),
              ],
            )
          : Text(t.dialog_import),
    );
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
