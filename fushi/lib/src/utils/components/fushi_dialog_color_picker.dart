import 'dart:math' as math;

import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:material_ui/material_ui.dart';

/// 对话框里内嵌的整块取色器（色板 + 色相条 + Hex 输入），按对话框**实际给到的**
/// 内容区尺寸自适应排版（反馈 PM-iIH9G0b）。
///
/// 包内 [ColorPicker] 的色板是写死的 `colorPickerWidth × colorPickerWidth *
/// pickerAreaHeightPercent`（默认 300×300），各调用处原来直接把它塞进
/// `SingleChildScrollView`：手机横屏（384dp 高）时对话框内容区只剩 ~100dp，色板
/// 被裁成一条、下面的色相条（换色系）与 Hex 输入完全看不见，而色板本身吃掉竖向
/// 拖动——滚动视图也滚不下去，用户只能在被裁掉的色板里「盲拖」。
///
/// 这里改为由内容区约束反推尺寸：
/// - 竖排：色板宽取 `min(可用宽, 300)`，高取「可用高 − 色相条/Hex 固定高度」，
///   保证色相条和 Hex 输入始终在可见区内；
/// - 横屏且高度不够全尺寸竖排时：在「竖排压缩」与包内横排布局（色板在左、色相条
///   与 Hex 在右，色板高度贴满可用高度）之间挑一屏放得下且色板面积更大的那种。
///
/// 外层仍包一层 `SingleChildScrollView` 兜底（超大字号等估算不到的情况可滚动），
/// 但正常尺寸下整块取色器一屏放得下，不再依赖滚动。
class FushiDialogColorPicker extends StatelessWidget {
  /// 创建自适应取色器。
  const FushiDialogColorPicker({
    super.key,
    required this.pickerColor,
    required this.onColorChanged,
    this.enableAlpha = false,
  });

  /// 初始颜色。
  final Color pickerColor;

  /// 拖动 / 输入时的颜色回调（与 [ColorPicker.onColorChanged] 同义）。
  final ValueChanged<Color> onColorChanged;

  /// 是否显示透明度滑条。
  final bool enableAlpha;

  /// 色板的首选边长（与包内默认 `colorPickerWidth` 一致）。
  static const double preferredPaletteExtent = 300;

  /// 色板最小高度：再小就点不准了，宁可让外层滚动。
  static const double minPaletteExtent = 72;

  /// 包内横排布局右栏写死的宽度：`20 + ColorIndicator(50) + 滑条(260) + 10`。
  static const double sideControlsWidth = 340;

  /// 低于该高度的窗口视作「矮屏」（手机横屏等）：调用方据此省掉对话框的 hero
  /// 图标，把纵向空间让给取色器（见 [compactHeight]）。
  static const double compactHeightBreakpoint = 480;

  /// 当前窗口是否矮屏。取色对话框在矮屏下应省略 hero 图标。
  static bool compactHeight(BuildContext context) =>
      MediaQuery.sizeOf(context).height < compactHeightBreakpoint;

  /// 竖排时色板以外的固定高度：色相条行（上下各 5 padding + max(指示圆 50,
  /// 滑条 40 × 条数)）+ Hex 输入行（顶 5 + 稠密输入框）+ 包内底部 20 留白。
  static double portraitChromeHeight(BuildContext context, bool enableAlpha) {
    final double sliders = enableAlpha ? 80 : 40;
    final double sliderRow = 10 + math.max(50, sliders);
    return sliderRow + _hexInputHeight(context) + 20;
  }

  /// Hex 输入行高度估算：顶部 5 padding + 稠密 TextField（字高 + 上下 5 内边距 +
  /// 下划线）。随系统字号缩放。
  static double _hexInputHeight(BuildContext context) {
    final double fontSize =
        Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16;
    final double scaled = MediaQuery.textScalerOf(context).scale(fontSize);
    return 5 + scaled * 1.5 + 10 + 2;
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final bool landscape = screen.width > screen.height;
    // 首选宽度只用于对话框的 IntrinsicWidth 量宽；真正的宽高以下面
    // LayoutBuilder 拿到的约束为准（对话框会把超出的首选宽度夹回去）。
    final double preferredWidth = landscape && compactHeight(context)
        ? preferredPaletteExtent + sideControlsWidth
        : preferredPaletteExtent;
    return SizedBox(
      width: preferredWidth,
      child: LayoutBuilder(
        builder: (BuildContext layoutContext, BoxConstraints constraints) {
          return SingleChildScrollView(
            child: _buildSized(layoutContext, constraints, landscape),
          );
        },
      ),
    );
  }

  Widget _buildSized(
    BuildContext context,
    BoxConstraints constraints,
    bool landscape,
  ) {
    final double width = constraints.maxWidth;
    final double height = constraints.maxHeight;
    final double chrome = portraitChromeHeight(context, enableAlpha);
    final double portraitExtent = math.min(width, preferredPaletteExtent);
    final bool fitsPortrait =
        !height.isFinite || height >= portraitExtent + chrome;
    // 竖排压缩色板高度后的色板高（< minPaletteExtent 即竖排一屏放不下）。
    final double portraitPaletteHeight = height.isFinite
        ? math.min(height - chrome, portraitExtent)
        : portraitExtent;
    // 横排：右栏写死 sideControlsWidth，色板吃剩下的宽、贴满可用高。
    final double sidePaletteWidth = math.min(
      width - sideControlsWidth,
      preferredPaletteExtent,
    );
    final double sidePaletteHeight = math.min(height, sidePaletteWidth);
    // 横屏且竖排放不下全尺寸时，在「竖排压缩」与「横排」里挑**一屏放得下且色板
    // 面积更大**的那种：只按固定最小宽度判横排，会在对话框内容区偏窄时（Apple
    // sheet 最宽 520 − 两侧 24 内边距 = 472）退回一屏放不下的竖排，色板又吃掉
    // 竖向拖动、滚不到色相条（PM-iIH9G0b Apple 设计系统横屏）。
    final bool sideFits = sidePaletteWidth >= minPaletteExtent;
    final bool portraitFits = portraitPaletteHeight >= minPaletteExtent;
    final bool side =
        landscape &&
        !fitsPortrait &&
        sideFits &&
        (!portraitFits ||
            sidePaletteWidth * sidePaletteHeight >=
                portraitExtent * portraitPaletteHeight);
    if (side) {
      return _picker(
        portraitOnly: false,
        paletteWidth: sidePaletteWidth,
        paletteHeight: math.max(sidePaletteHeight, minPaletteExtent),
      );
    }
    final double paletteHeight = math.max(
      portraitPaletteHeight,
      math.min(minPaletteExtent, portraitExtent),
    );
    return _picker(
      portraitOnly: true,
      paletteWidth: portraitExtent,
      paletteHeight: paletteHeight,
    );
  }

  Widget _picker({
    required bool portraitOnly,
    required double paletteWidth,
    required double paletteHeight,
  }) {
    return ColorPicker(
      pickerColor: pickerColor,
      onColorChanged: onColorChanged,
      portraitOnly: portraitOnly,
      colorPickerWidth: paletteWidth,
      pickerAreaHeightPercent: paletteHeight / paletteWidth,
      enableAlpha: enableAlpha,
      displayThumbColor: true,
      hexInputBar: true,
      labelTypes: const <ColorLabelType>[],
    );
  }
}
