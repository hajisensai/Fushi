import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

// 播放器设置类浮层（设置侧板 / 字幕轨 / 音轨 / 画质 / 章节 / 弹幕匹配 / 字幕调整
// 抽屉 / 剧集轨道）的 M3 Expressive 配色。
//
// 这些面板浮在画面上，与顶 / 底栏胶囊、音量 / 倍速浮层是同一层「播放器 chrome」，
// 所以底色统一用无色相中性深色（[videoM3eFloatingColor]，#2D2D2D @86%），内部
// 控件读一份中性主题：表面族是不带色相的灰阶、前景纯白 / 白 70%，强调色族仍以
// app 主色为种子（开关「开」态、选中行、滑条已走段）。浅色主题下也不会黑压黑。
//
// 为什么不是 `Theme.of(context).copyWith(colorScheme: …)`：主题工厂把 scheme 颜色
// **烤进**了组件主题（列表选中底、开关轨道、菜单底……），只换 colorScheme 时那些
// 组件仍是 app 的浅色值；这里经 [rethemeFushiWithScheme] 重走工厂，字阶也按新前景
// 重新着色。Apple 设计系统与墨水屏不经这里（各自保持原样）。

/// 当前 context 下播放器面板是否走 M3E 中性深色（非 Apple、非墨水屏）。
bool videoM3ePanelNeutral(BuildContext context) =>
    !isGlassDesign(context) && !isEinkTheme(context);

final Map<int, ColorScheme> _panelSchemeCache = <int, ColorScheme>{};

/// 面板内的中性配色：在 [videoM3eNeutralChromeScheme] 的基础上把容器族整体提
/// 一档——面板底本身就是 #2D2D2D，分组卡 / 内卡 / 关态开关轨道要比它亮才分得出
/// 层次（MD3 深色方案里容器色恒比表面亮）。
ColorScheme videoM3ePanelScheme(ColorScheme cs) {
  final int key = cs.primary.toARGB32();
  return _panelSchemeCache[key] ??= videoM3eNeutralChromeScheme(cs).copyWith(
    surfaceContainerLowest: const Color(0xFF262626),
    surfaceContainerLow: const Color(0xFF393939),
    surfaceContainer: const Color(0xFF3E3E3E),
    surfaceContainerHigh: const Color(0xFF444444),
    surfaceContainerHighest: const Color(0xFF4E4E4E),
    surfaceBright: const Color(0xFF575757),
  );
}

final Expando<ThemeData> _panelThemeCache = Expando<ThemeData>(
  'videoM3ePanelTheme',
);

/// 按**值**命中的最近几份结果（实例缓存未命中时的第二层）。
///
/// `Theme.of` 每次返回的是 `ThemeData.localize` 的产物，而那层 memo 只是 5 格
/// FIFO：主题稍多（面板主题自己也要 localize）就被挤掉，同一份 app 主题每次
/// rebuild 换一个新实例。只按实例缓存时面板每次 setState（时间轴滚动 30fps）都
/// 重走整套主题工厂；产物里的组件主题带闭包、`==` 不等，`Theme` 于是逐帧通知，
/// 面板内所有 `Theme.of` 依赖者跟着重建——横向 `Scrollable` 也在其中，
/// `didChangeDependencies` 把 [ScrollPosition] 整个换掉。
final List<(ThemeData, ThemeData)> _panelThemeByValue =
    <(ThemeData, ThemeData)>[];
const int _panelThemeByValueSize = 4;

/// [base] 换成面板中性配色后重走主题工厂的结果（按 [base] 实例缓存，实例未命中
/// 再按值找，保证同一份 app 主题恒得到同一个面板主题实例）。
ThemeData videoM3ePanelTheme(ThemeData base) {
  final ThemeData? cached = _panelThemeCache[base];
  if (cached != null) return cached;
  for (final (ThemeData seenBase, ThemeData seenTheme) in _panelThemeByValue) {
    if (seenBase == base) {
      _panelThemeCache[base] = seenTheme;
      return seenTheme;
    }
  }
  final ColorScheme scheme = videoM3ePanelScheme(base.colorScheme);
  final ThemeData recolored = base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
  );
  final ThemeData theme = rethemeFushiWithScheme(recolored, scheme);
  _panelThemeCache[base] = theme;
  if (_panelThemeByValue.length >= _panelThemeByValueSize) {
    _panelThemeByValue.removeAt(0);
  }
  _panelThemeByValue.add((base, theme));
  return theme;
}

/// 把 [child] 放进面板中性主题（M3E）；Apple / 墨水屏原样返回。
class VideoM3ePanelTheme extends StatelessWidget {
  const VideoM3ePanelTheme({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!videoM3ePanelNeutral(context)) return child;
    return Theme(data: videoM3ePanelTheme(Theme.of(context)), child: child);
  }
}

/// 面板列表行的选中前景：Apple 沿用强调色（原样）；M3E / 墨水屏交给列表主题
/// （M3E = onSecondaryContainer 压 secondaryContainer 选中块，墨水屏 = 默认 primary）。
Color? videoPanelSelectedForeground(BuildContext context) =>
    isGlassDesign(context) ? Theme.of(context).colorScheme.primary : null;

/// 面板里纵向列表的内边距：M3E 左右留 8，选中行的圆角色块浮在面板里、不贴边；
/// Apple / 墨水屏保持原来的上下 8。
EdgeInsets videoPanelListPadding(BuildContext context) =>
    videoM3ePanelNeutral(context)
    ? const EdgeInsets.fromLTRB(8, 4, 8, 16)
    : const EdgeInsets.symmetric(vertical: 8);
