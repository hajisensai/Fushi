/// Apple（Cupertino）设计系统下「对话框级」工作面的呈现：macOS 档是窗口 sheet，
/// iOS 档是整页（用户 2026-11-24 拍板：捕获设置 / 校准这类工作面不在 Apple 下
/// 弹 MD3 式居中对话框）。档位判据只有 [fushiAppleUsesMacMetrics] 一处。
///
/// 用法：调用方用 [showAdaptiveDialogSurface]（M3E 仍是 [showAppDialog] 对话框）或
/// 直接 [showFushiAppleSurface] 推出去；被推出去的 widget 用
/// [FushiAppleSurfaceScope.maybeFormOf] 判断自己在不在 Apple 工作面里——在就把
/// 标题 / 内容体 / 动作交给 [FushiAppleSurfaceFrame]，不在就照旧套对话框外壳。
/// 内容体与状态只有一份，外壳按设计系统分派。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet, adaptivePageRoute;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadScaffold;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiDialogActionScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiDividerControl, fushiAppleUsesMacMetrics;
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// Apple 工作面的两种形态。
enum FushiAppleSurfaceForm {
  /// macOS 档：窗口正中的 sheet（[adaptiveModalSheet] 的桌面分支）。
  sheet,

  /// iOS 档：推入的整页（[FushiMastheadScaffold]），返回 = 取消。
  page,
}

/// 标记「这棵子树是 Apple 工作面的内容」，并告诉它是 sheet 还是整页。形态在推出去
/// 那一刻定下，之后窗口再缩放也不在 sheet 里改画整页（反之亦然）。
class FushiAppleSurfaceScope extends InheritedWidget {
  const FushiAppleSurfaceScope({
    required this.form,
    required super.child,
    super.key,
  });

  final FushiAppleSurfaceForm form;

  /// 不在 Apple 工作面里（M3E 对话框、或直接嵌在页面里）时为 null。
  static FushiAppleSurfaceForm? maybeFormOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiAppleSurfaceScope>()
      ?.form;

  @override
  bool updateShouldNotify(FushiAppleSurfaceScope oldWidget) =>
      form != oldWidget.form;
}

/// 推出一个 Apple 工作面：macOS 档 sheet、iOS 档整页，返回值语义与对话框一致
/// （`Navigator.pop(result)`；整页的返回手势 / 返回键、sheet 的 Esc 都是 null）。
///
/// [dismissible] 为 false 对应对话框的 `barrierDismissible: false`：sheet 点外部
/// 不关（Esc 仍是明确的关闭意图，照常 pop）；整页本来就没有「外部」，返回即取消。
Future<T?> showFushiAppleSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  if (fushiAppleUsesMacMetrics(context)) {
    return adaptiveModalSheet<T>(
      context: context,
      isDismissible: dismissible,
      builder: (BuildContext sheetContext) => FushiAppleSurfaceScope(
        form: FushiAppleSurfaceForm.sheet,
        child: Builder(builder: builder),
      ),
    );
  }
  return Navigator.of(context).push<T>(
    adaptivePageRoute<T>(
      context: context,
      builder: (BuildContext pageContext) => FushiAppleSurfaceScope(
        form: FushiAppleSurfaceForm.page,
        child: Builder(builder: builder),
      ),
    ),
  );
}

/// 对话框级工作面的唯一分派：Apple 设计系统走 [showFushiAppleSurface]（macOS 档
/// sheet / iOS 档整页），M3E 照旧 [showAppDialog]。
Future<T?> showAdaptiveDialogSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  if (isGlassDesign(context)) {
    return showFushiAppleSurface<T>(
      context: context,
      builder: builder,
      dismissible: barrierDismissible,
    );
  }
  return showAppDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
  );
}

/// Apple 工作面的外壳：按 [FushiAppleSurfaceScope] 的形态画成
/// - sheet：[FushiModalSheetFrame]（标题在头部，[actions] 右对齐排在底部动作区）；
/// - 整页：[FushiMastheadScaffold]（标题进大标题导航栏，[actions] 排在底部动作条，
///   返回 = 取消，所以整页里调用方不必再放「关闭」）。
///
/// [scrollable] 为 false 时内容体自己处理滚动并填满可用高度（双栏工作区等）。
///
/// Apple 专用件（@design cupertino）：只在 [showFushiAppleSurface] 推出来的子树里
/// 用；M3E 的对应物是调用方自己的对话框外壳（`FushiAlertDialog` 等），由
/// [FushiAppleSurfaceScope.maybeFormOf] 在调用方分派，本件不带 M3E 分支。
class FushiAppleSurfaceFrame extends StatelessWidget {
  const FushiAppleSurfaceFrame({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.scrollable = true,
    this.bodyPadding,
    super.key,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool scrollable;

  /// 内容体四周留白；null = sheet 与头部同宽的页边、整页左右 16。整页另外叠加
  /// 页头让位与底部安全区。
  final EdgeInsets? bodyPadding;

  @override
  Widget build(BuildContext context) {
    final FushiAppleSurfaceForm form =
        FushiAppleSurfaceScope.maybeFormOf(context) ??
        (fushiAppleUsesMacMetrics(context)
            ? FushiAppleSurfaceForm.sheet
            : FushiAppleSurfaceForm.page);
    final Widget? actionRow = actions.isEmpty
        ? null
        : Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          );
    if (form == FushiAppleSurfaceForm.sheet) {
      final double pad = FushiDesignTokens.of(context).spacing.page;
      return FushiModalSheetFrame(
        title: title,
        scrollable: scrollable,
        bodyPadding: bodyPadding ?? EdgeInsets.fromLTRB(pad, 0, pad, pad),
        body: body,
        footer: actionRow,
      );
    }
    final EdgeInsets inset =
        bodyPadding ?? const EdgeInsets.fromLTRB(16, 8, 16, 16);
    return FushiMastheadScaffold(
      title: title,
      bottomNavigationBar: actionRow == null
          ? null
          : _PageActionBar(child: actionRow),
      body: Builder(
        builder: (BuildContext context) {
          // 大标题导航栏把页头高度注入成 MediaQuery.padding.top。
          final EdgeInsets safe = MediaQuery.paddingOf(context);
          final EdgeInsets padding = inset.copyWith(
            top: inset.top + safe.top,
            bottom: inset.bottom + safe.bottom,
          );
          if (scrollable) {
            return ListView(
              primary: false,
              padding: padding,
              children: <Widget>[body],
            );
          }
          return Padding(padding: padding, child: body);
        },
      ),
    );
  }
}

/// 整页底部动作条：细分隔线 + 右对齐的一排按钮（与 sheet 底部动作区同一种胶囊）。
class _PageActionBar extends StatelessWidget {
  const _PageActionBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double pad = FushiDesignTokens.of(context).spacing.page;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const FushiDividerControl(height: 1),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 10, pad, 10),
            child: FushiDialogActionScope(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
