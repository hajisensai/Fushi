import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleDarkTier;

/// 歌词模式配色的**唯一注入点**：包在阅读器页面外面（路由 builder 里），歌词
/// 模式开着时把整页（连同页面 context 弹出的菜单、侧栏、对话框、查词浮层）换成
/// 歌词模式的主题——MD3 是按封面取色重走工厂的主题，Apple 是深色档主题。
///
/// 为什么要在页面**外面**：阅读器的侧栏 / 对话框都用页面 State 的 context 弹出，
/// 路由从这个 context 往上捕获主题；页面自己 build 里包的 Theme 在 context 之下，
/// 捕获不到。歌词覆盖层（[ReaderLyricsPlayerOverlay]）挂载即登记、封面取色到达时
/// 上报 scheme、卸载即撤回；没有歌词模式时这层只是原样透传根主题。
///
/// 结构恒定：无论是否覆盖都是同一个 [Theme] 包装，切歌词模式不重建页面子树。
class LyricsThemeHost extends StatefulWidget {
  const LyricsThemeHost({required this.child, super.key});

  final Widget child;

  /// 最近的宿主（没有挂宿主的页面——测试、其它入口——返回 null，覆盖层照常工作，
  /// 只是弹出层沿用外层主题）。
  static LyricsThemeHostState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<LyricsThemeHostState>();

  @override
  State<LyricsThemeHost> createState() => LyricsThemeHostState();
}

class LyricsThemeHostState extends State<LyricsThemeHost> {
  Object? _owner;
  ColorScheme? _coverScheme;

  ThemeData? _cacheBase;
  ColorScheme? _cacheScheme;
  ThemeData? _cached;

  /// 歌词模式是否正在覆盖页面主题（测试断言用）。
  bool get active => _owner != null;

  /// 歌词覆盖层登记 / 更新：[coverScheme] 为封面取色结果（尚未到达时 null，
  /// MD3 先沿用根主题、Apple 恒用深色档）。
  void attach(Object owner, ColorScheme? coverScheme) {
    if (identical(_owner, owner) && identical(_coverScheme, coverScheme)) {
      return;
    }
    _owner = owner;
    _coverScheme = coverScheme;
    _markDirty();
  }

  /// 歌词覆盖层卸载时撤回（只撤回自己登记的那份）。
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _coverScheme = null;
    _markDirty();
  }

  void _markDirty() {
    if (!mounted) return;
    // 覆盖层在自己的 build / dispose 里登记，而宿主是它的祖先：构建阶段直接
    // setState 会在构建中把祖先标脏（断言失败）。挪到本帧收尾，同
    // FushiDesktopTitleBar.setPageColors。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  ThemeData _themeFor(ThemeData base) {
    if (_owner == null) return base;
    final ColorScheme? scheme = _coverScheme;
    final bool apple = base.extension<FushiGlassTheme>()?.glassDesign == true;
    if (!apple && scheme == null) return base;
    final ThemeData? cached = _cached;
    if (cached != null &&
        identical(base, _cacheBase) &&
        identical(scheme, _cacheScheme)) {
      return cached;
    }
    _cacheBase = base;
    _cacheScheme = scheme;
    // Apple 歌词页恒是深底：整页用深色档（与覆盖层控件同一份），不吃封面色。
    return _cached = apple
        ? FushiAppleDarkTier.darkTierOf(base)
        : rethemeFushiWithScheme(base, scheme!);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(data: _themeFor(Theme.of(context)), child: widget.child);
  }
}
