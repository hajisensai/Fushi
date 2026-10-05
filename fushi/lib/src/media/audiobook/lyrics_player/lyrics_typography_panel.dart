// 歌词模式「Aa」文字快捷面板（2026-10，用户：「歌词模式字体调节感觉还需要个
// 入口」——此前歌词字号只能去 阅读设置 ›「歌词模式」页调，太深）。
//
// 歌词覆盖层控件条上的「Aa」键点开：宽屏是锚定在按钮上的 popover（与倍速面板
// 同一条锚定路由 [showLyricsAnchoredPanel]），窄屏（< 600）是底部 sheet。内容只放
// 已有的歌词偏好，不新造：
//  * 字号（`lyrics_font_size`，8–64）：M3E 滑块 + ±步进 + 大号读数，拖动实时生效
//    ——写偏好后走页面的热更样式通道（`__lyricsUpdateStyle`），不重载歌词页；
//  * 竖排（`lyrics_vertical_writing`）：切换要整页重建（排版方向变了），由页面
//    的 `_loadLyricsPage` 负责；
//  * 字体：歌词没有独立字体偏好，跟随阅读器字体（面板里说明一句）；
//  * 「更多歌词设置」：关面板、打开阅读设置的「歌词模式」页。
//
// 键盘：面板打开即把焦点交给字号滑块（←/→ 一档），Tab 到 ± / 竖排 / 更多，Esc 关闭，
// 焦点回到「Aa」键（路由出栈时 Flutter 还原原焦点）。
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 歌词字号范围（与阅读设置「歌词模式」页的步进器一致）。
const double kLyricsFontSizeMin = 8;
const double kLyricsFontSizeMax = 64;

/// 面板根节点 key（测试用）。
const ValueKey<String> kLyricsTypographyPanelKey = ValueKey<String>(
  'lyrics_typography_panel',
);

/// 字号滑块 key。
const ValueKey<String> kLyricsTypographyFontSliderKey = ValueKey<String>(
  'lyrics_typography_font_slider',
);

/// 弹出「Aa」面板。宽屏锚定 popover、窄屏底部 sheet；面板关闭时 Future 完成。
Future<void> showLyricsTypographyPanel({
  required BuildContext anchorContext,
  required double fontSize,
  required bool vertical,
  required ValueChanged<double> onFontSizeChanged,
  required ValueChanged<bool> onVerticalChanged,
  required VoidCallback onOpenMore,
}) {
  Widget panel(BuildContext ctx) => LyricsTypographyPanel(
    fontSize: fontSize,
    vertical: vertical,
    onFontSizeChanged: onFontSizeChanged,
    onVerticalChanged: onVerticalChanged,
    onOpenMore: () {
      Navigator.of(ctx).maybePop();
      onOpenMore();
    },
  );
  if (MediaQuery.sizeOf(anchorContext).width < 600) {
    return showModalBottomSheet<void>(
      context: anchorContext,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: panel(ctx),
        ),
      ),
    );
  }
  return showLyricsAnchoredPanel(anchorContext: anchorContext, builder: panel);
}

/// 面板本体（可单独测试）。
class LyricsTypographyPanel extends StatefulWidget {
  const LyricsTypographyPanel({
    super.key = kLyricsTypographyPanelKey,
    required this.fontSize,
    required this.vertical,
    required this.onFontSizeChanged,
    required this.onVerticalChanged,
    required this.onOpenMore,
  });

  final double fontSize;
  final bool vertical;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<bool> onVerticalChanged;
  final VoidCallback onOpenMore;

  @override
  State<LyricsTypographyPanel> createState() => _LyricsTypographyPanelState();
}

class _LyricsTypographyPanelState extends State<LyricsTypographyPanel> {
  late double _size = widget.fontSize
      .clamp(kLyricsFontSizeMin, kLyricsFontSizeMax)
      .roundToDouble();
  late bool _vertical = widget.vertical;

  void _setSize(double v) {
    final double next = v
        .clamp(kLyricsFontSizeMin, kLyricsFontSizeMax)
        .roundToDouble();
    if (next == _size) return;
    setState(() => _size = next);
    widget.onFontSizeChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fg = glass ? appleColorsOf(context).label : scheme.onSurface;
    final Color secondary = glass
        ? appleColorsOf(context).secondaryLabel
        : scheme.onSurfaceVariant;
    final Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiIcon(Icons.text_fields_rounded, color: fg, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.lyrics_font_size,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // Display 级大号读数（M3E Emphasized 字阶）。
              Text(
                '${_size.round()}',
                key: const ValueKey<String>('lyrics_typography_font_value'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: glass ? appleColorsOf(context).accent : scheme.primary,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              FushiIconButtonControl.filledTonal(
                key: const ValueKey<String>('lyrics_typography_font_minus'),
                tooltip: '−1',
                onPressed: _size <= kLyricsFontSizeMin
                    ? null
                    : () => _setSize(_size - 1),
                icon: const FushiIcon(Icons.remove_rounded),
              ),
              Expanded(
                child: FushiSlider(
                  key: kLyricsTypographyFontSliderKey,
                  value: _size,
                  min: kLyricsFontSizeMin,
                  max: kLyricsFontSizeMax,
                  divisions: (kLyricsFontSizeMax - kLyricsFontSizeMin).round(),
                  autofocus: true,
                  onChanged: _setSize,
                ),
              ),
              FushiIconButtonControl.filledTonal(
                key: const ValueKey<String>('lyrics_typography_font_plus'),
                tooltip: '+1',
                onPressed: _size >= kLyricsFontSizeMax
                    ? null
                    : () => _setSize(_size + 1),
                icon: const FushiIcon(Icons.add_rounded),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t.lyrics_typography_font_follows_reader,
            style: theme.textTheme.bodySmall?.copyWith(color: secondary),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.lyrics_vertical_writing,
                  style: theme.textTheme.bodyLarge?.copyWith(color: fg),
                ),
              ),
              FushiSwitch(
                key: const ValueKey<String>('lyrics_typography_vertical'),
                value: _vertical,
                onChanged: (bool v) {
                  setState(() => _vertical = v);
                  widget.onVerticalChanged(v);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FushiTextButton.icon(
              key: const ValueKey<String>('lyrics_typography_more'),
              onPressed: widget.onOpenMore,
              icon: const FushiIcon(Icons.tune_rounded),
              label: Text(t.lyrics_typography_more_settings),
            ),
          ),
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: FushiGlassSurface(
        borderRadius: BorderRadius.all(Radius.circular(glass ? 22 : 28)),
        child: body,
      ),
    );
  }
}

/// 页面侧的写回：字号写偏好后经 [applyLive] 热更歌词样式（不重载页面）；竖排写
/// 偏好后经 [reload] 整页重建。拆成纯函数供测试。
Future<void> applyLyricsFontSize({
  required double value,
  required Future<void> Function(double) write,
  required Future<void> Function() applyLive,
}) async {
  await write(value);
  await applyLive();
}

/// 竖排切换：写偏好 + 整页重建（排版方向变了，热更不够）。
Future<void> applyLyricsVertical({
  required bool value,
  required Future<void> Function(bool) write,
  required Future<void> Function() reload,
}) async {
  await write(value);
  unawaited(reload());
}
