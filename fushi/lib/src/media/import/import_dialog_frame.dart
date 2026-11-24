import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_block_color_scope.dart'
    show FushiBlockColorScope, FushiNeutralColorScope;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// 所有导入类对话框的共享外框（2026-11 导入对话框统一：书 / 有声书 / 漫画 /
/// OCR / 视频 / IPTV / 粘贴文本 / 网络来源 / 字幕书重导入 / mokuro / 二选一 /
/// 音乐光盘）。统一的设计规则：
///
/// - **头部**：一律左对齐标题 + 一行说明（MD3 / Apple 同口径），不画居中 hero
///   图标——表单型对话框的视觉重心在正文第一组选择项，头部再顶一枚图标就是两个
///   重心（此前书是左对齐、漫画 / 视频是居中 hero，用户嫌割裂）。标题固定在顶部，
///   不随正文滚动。
/// - **正文**：对话框是外层导入拼贴面的缩小版（第二版，用户「导入框要和外层
///   一样有大色块」）：主选择是模块色反色大色块 [ImportPickBlock]（也是拖放
///   落点），次要选择是钉色小色块 [ImportPickTile] 网格（封面格带缩略图），
///   表单分组是 [ImportSectionBlock] 色块；色块件都在 `import_dialog_blocks.dart`，
///   取色 / glyph / 外形全部复用外层拼贴。文本字段统一 M3E 填充式
///   [FushiTextField]，用 [FushiFormSection] 排成一致的字段节奏（字段间 12、
///   块间 12、组间 20）。
/// - **按钮区**：[actions] 靠右（取消 + 主操作，主操作在最右）；[secondaryActions]
///   靠左（「测试连接」「OCR 导入漫画」这类次要但独立的动作），窄屏自动折行。
///
/// FushiDialogFrame 560/0.86 + FushiModalSheetFrame 同 padding；空 actions 且无
/// secondaryActions 时无 footer。
class ImportDialogFrame extends StatelessWidget {
  const ImportDialogFrame({
    required this.body,
    required this.actions,
    this.title,
    this.subtitle,
    this.secondaryActions = const <Widget>[],
    this.maxWidth = 560,
    this.tone,
    super.key,
  });

  /// 模块色系（书 coral / 漫画 violet / 视频 cyan…）：整个对话框（面板、头部、
  /// 按钮区、主按钮 / 文字按钮、聚焦色）换成这个色相的 M3 配色方案，与正文里
  /// 的同色系色块是一家。null = 主题中性面板（多色选项的二选一对话框）。
  /// 只在 MD3 生效；Apple 液态玻璃与墨水屏不变。
  final ImportTone? tone;

  final String? title;

  /// 标题下的一行说明（对话框 supporting text）。
  final String? subtitle;
  final Widget body;

  /// 右侧按钮（取消 + 主操作）。
  final List<Widget> actions;

  /// 左侧次要动作（见类注释）。
  final List<Widget> secondaryActions;

  /// 面板最大宽度。宽屏两栏版式的对话框放宽。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    Widget wrap(List<Widget> children) =>
        Wrap(spacing: gap, runSpacing: gap, children: children);
    final Widget? footer;
    if (actions.isEmpty && secondaryActions.isEmpty) {
      footer = null;
    } else if (secondaryActions.isEmpty) {
      footer = Wrap(
        alignment: WrapAlignment.end,
        spacing: gap,
        runSpacing: gap,
        children: actions,
      );
    } else {
      // 左右两簇：宽度够时分列两端，窄屏折成两行（次要在上、主次在下靠右）。
      footer = SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[wrap(secondaryActions), wrap(actions)],
        ),
      );
    }
    if (isGlassDesign(context)) return _buildApple(context, footer);
    final Widget frame = FushiDialogFrame(
      maxWidth: maxWidth,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: title,
        subtitle: subtitle,
        // 左右 24 与对话框头部同一条边（块、网格、表单、按钮区都对齐标题）；
        // 正文到按钮区 16，与头部到正文的 16 对称。
        bodyPadding: const EdgeInsets.symmetric(horizontal: 24),
        footerPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        scrollable: true,
        body: body,
        footer: footer,
      ),
    );
    final ThemeData? toned = importToneThemeOrNull(context, tone);
    return toned == null ? frame : Theme(data: toned, child: frame);
  }

  /// Apple（Cupertino）设计系统：iOS 27 / macOS 27 的 sheet 表单。
  ///
  /// - 配色一律中性（系统灰 + 强调色）：[tone] 不生效，从导入页色块弹出也经
  ///   [FushiNeutralColorScope] 退出块配色——此前承接了色块的深棕前景，标题在
  ///   深色玻璃面板上几乎看不见，正文全是暖色色块。
  /// - 正文是 inset grouped 列表（色块件的 Apple 分支，见
  ///   `import_dialog_blocks.dart`），iOS 档 / macOS 档的行高、字号、圆角都由
  ///   [FushiAppleMetrics] 按窗口宽度判（`fushiAppleUsesMacMetrics`）。
  /// - 标题固定在顶部；正文在自己的滚动视口里滚，滚离顶部 / 底部还有内容时
  ///   边缘柔和渐隐（scroll edge），内容不再一刀切在标题下沿。
  /// - 按钮区沿用 Apple sheet 的动作区（右下，主操作最右）。
  Widget _buildApple(BuildContext context, Widget? footer) {
    return FushiNeutralColorScope(
      child: FushiDialogFrame(
        maxWidth: maxWidth,
        maxHeightFactor: 0.86,
        scrollable: false,
        child: FushiModalSheetFrame(
          title: title,
          subtitle: subtitle,
          footerPadding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          body: FushiHorizontalEdgeFade(
            axis: Axis.vertical,
            extent: 20,
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: body,
            ),
          ),
          footer: footer,
        ),
      ),
    );
  }
}

/// [importDialogTheme] 的设计系统门：null 模块色、Apple 液态玻璃、墨水屏都
/// 返回 null（保持主题原样）。导入流程里另开的弹层（设备端转录…）同样用它。
ThemeData? importToneThemeOrNull(BuildContext context, ImportTone? tone) {
  if (tone == null || isGlassDesign(context) || isEinkTheme(context)) {
    return null;
  }
  // 从带色组件弹出（子树已是那块的局部配色，见 FushiBlockColorScope）：承接
  // 来源组件的配色，不再按模块色另换一套。
  if (FushiBlockColorScope.maybeColorsOf(context)?.hue != null) return null;
  return importDialogTheme(context, tone);
}

final Map<(double, Brightness), ColorScheme> _importDialogSchemes =
    <(double, Brightness), ColorScheme>{};

/// [ImportDialogFrame.tone] 的主题：以模块色相为种子的 M3 tonal-spot 配色——
/// 面板 / 容器色是该色相的低彩度中性面（不是强调色），primary 是同色相的
/// 可读强调色（M3 方案自带对比度）。对话框面板色沿用主题的不透明度（毛玻璃
/// 半透明档仍半透明）。配色方案按（色相、明暗）缓存。
ThemeData importDialogTheme(BuildContext context, ImportTone tone) {
  final ThemeData theme = Theme.of(context);
  final Brightness brightness = theme.colorScheme.brightness;
  final ColorScheme scheme = _importDialogSchemes.putIfAbsent(
    (tone.hue, brightness),
    () => ColorScheme.fromSeed(
      seedColor: HSLColor.fromAHSL(1, tone.hue, 0.6, 0.5).toColor(),
      brightness: brightness,
    ),
  );
  final Color? panel = theme.dialogTheme.backgroundColor;
  return theme.copyWith(
    colorScheme: scheme,
    dialogTheme: theme.dialogTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh.withValues(
        alpha: panel?.a ?? 1,
      ),
    ),
  );
}
