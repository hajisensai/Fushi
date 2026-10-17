import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

// 播放器设置类浮层（设置侧板 / 字幕轨 / 音轨 / 画质 / 章节 / 弹幕匹配 / 字幕调整
// 抽屉 / 剧集轨道）的 M3 Expressive 配色。
//
// 这些面板浮在画面上，与顶 / 底栏胶囊、音量 / 倍速浮层是同一层「播放器 chrome」，
// 配色跟随 app 的日间 / 深色模式（2026-10-14 用户：日间模式下面板是固定深色、
// 旁边的面板切换竖条却是浅色，一深一浅）：内部控件读以 app 主色为种子、与 app
// 同亮度的着色方案（[videoM3eChromeScheme]），面板切换竖条也套同一份主题
// （video_side_panel.dart），二者恒同色。
//
// 为什么不是 `Theme.of(context).copyWith(colorScheme: …)`：主题工厂把 scheme 颜色
// **烤进**了组件主题（列表选中底、开关轨道、菜单底……），只换 colorScheme 时那些
// 组件仍是 app 的浅色值；这里经 [rethemeFushiWithScheme] 重走工厂，字阶也按新前景
// 重新着色。Apple 设计系统与墨水屏不经这里（各自保持原样）。

/// 当前 context 下播放器面板是否走 M3E 面板主题（非 Apple、非墨水屏）。
bool videoM3ePanelNeutral(BuildContext context) =>
    !isGlassDesign(context) && !isEinkTheme(context);

/// 面板内的配色：以 app 主色为种子、与 app 同亮度的方案（[videoM3eChromeScheme]，
/// 按主色 + 亮度缓存），与阅读器侧板同一套表面层级——面板底 surfaceContainerLow、
/// 分组卡 surfaceContainer 往上，选中页签 / 行首图标块 / 开关都带主题色相
/// （2026-10-14 用户：播放器设置「很多地方都是灰色、没有着色」，要像阅读器设置
/// 那样）。日间模式下是浅色面板、深色模式下是深色面板（同日跟进：面板要吃 app
/// 的日间 / 深色模式）。播放器顶 / 底栏胶囊仍是中性表面，只有面板换成着色方案。
ColorScheme videoM3ePanelScheme(ColorScheme cs) => videoM3eChromeScheme(cs);

/// 面板表面色：着色方案的 surfaceContainerLow（[opaque] 时不透明，否则与播放器
/// 浮层同一不透明度——[videoM3eSurfaceAlpha]，画面隐约透出）。
Color videoM3ePanelSurfaceColor(ColorScheme cs, {required bool opaque}) {
  final Color base = videoM3ePanelScheme(cs).surfaceContainerLow;
  return opaque ? base : base.withValues(alpha: videoM3eSurfaceAlpha(cs));
}

/// 整页承载面板主题内容时的页底（网页视频页的加载 / 失败态）：深色模式与播放页
/// 同一块黑底；日间模式换成面板方案的 surface——面板主题此时是浅底深字，压在
/// 黑底上会黑压黑。
Color videoM3ePanelBackdrop(ColorScheme cs) => cs.brightness == Brightness.light
    ? videoM3ePanelScheme(cs).surface
    : Colors.black;

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
