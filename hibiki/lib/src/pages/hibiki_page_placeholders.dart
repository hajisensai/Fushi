import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';

/// 页面级「加载中 / 出错」占位的统一构建 mixin（审计 §1-K「页面骨架两套」）。
///
/// 此前 [buildError] / [buildLoading] 绑在 `BasePageState` 基类上，不挂
/// jidoujisho 体系 BasePage 的自立骨架页（游戏域、各对话框、manga/pdf 源页等）
/// 只能手抄 `Center(child: CircularProgressIndicator())` 与各自的错误占位。
/// 现收口到本 mixin：任何 [State] 子类 `with HibikiPagePlaceholders<T>` 即可
/// 复用，无须挂进 BasePage 家族；`BasePageState` 也改为混入本 mixin。
///
/// 默认样式取全 app 被最多页面使用的那份：
/// - 加载：居中不定尺寸 [adaptiveIndicator]（Material 下 = 裸
///   `CircularProgressIndicator()`：36 逻辑像素、主题主色，与既有手抄处逐像素
///   一致）。
/// - 出错：[HibikiPlaceholderMessage]（error_outline + 通用 i18n 文案 + 可选
///   重试按钮）。
/// 真实存在的样式差异（BasePage 家族历史的 25×25 主色圈、部分对话框的 24
/// 内边距等）通过参数保留，各调用点视觉不变。
mixin HibikiPagePlaceholders<T extends StatefulWidget> on State<T> {
  /// Standard loading circle for use across the application.
  ///
  /// [size]：给指示器套 [SizedBox] 的边长（BasePage 家族历史样式传 25）；
  /// null = 不约束（Material 默认 36）。[color]：指示器颜色；null = 主题默认
  /// （主色）。[padding]：指示器与 [Center] 之间的留白（部分对话框传 24）。
  Widget buildLoading({
    double? size,
    Color? color,
    EdgeInsetsGeometry? padding,
  }) {
    Widget indicator = adaptiveIndicator(context: context, color: color);
    if (size != null) {
      indicator = SizedBox(height: size, width: size, child: indicator);
    }
    if (padding != null) {
      indicator = Padding(padding: padding, child: indicator);
    }
    return Center(child: indicator);
  }

  /// Standard error message for use across the application.
  /// General widget for showing an error or a retry screen.
  ///
  /// 主文案是通用错误提示（i18n），原始异常串降级为折叠 detail（此前直接
  /// `'$error'` 上屏，用户看到的是 SqliteException(...) 原文）；调用方传了
  /// [refresh] 就渲染重试按钮（此前该参数被静默丢弃，页面没有任何恢复入口）。
  Widget buildError({
    Object? error,
    StackTrace? stack,
    Function()? refresh,
  }) {
    return Center(
      child: HibikiPlaceholderMessage(
        icon: Icons.error_outline,
        message: t.error_load_failed,
        detail: error != null ? '$error' : null,
        action: refresh != null
            ? FilledButton.tonalIcon(
                onPressed: () => refresh(),
                icon: const Icon(Icons.refresh),
                label: Text(t.retry),
              )
            : null,
      ),
    );
  }
}
