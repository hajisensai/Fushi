import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderSideSheet, ReaderSideSheetSide, showReaderSideSheet;
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart'
    show ReaderPanelEmpty;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/jump_history.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';

/// 媒体页「跳转记录」的共用 UI（小说阅读器含有声书 / 歌词模式、漫画阅读器、视频
/// 播放器）。所有者 2026-11-02 定稿，取代原先浮在内容上的胶囊：
///
/// - 顶栏右上角动作区最前面的**纯图标**：↶ 返回（一点即跳），走过返回后才多出
///   ↷ 前进；位置只进 tooltip / 语义。长按 / 右键打开「跳转记录」面板。没跳转过
///   不出现，跟着顶栏一起显隐，顶栏收着时跳转**不做任何提示**。
/// - 「跳转记录」面板（[showJumpHistoryPanel]）：本次会话的全部跳转，点哪条跳哪条，
///   页头「清除」。
/// - 进度条 / 页码滑块上的落点刻度（[FushiJumpProgressMarks]）。
/// - 设置三项（`jump_history_*`，三页共用）：顶栏图标开关（关了照样记录）、刻度开关、
///   顶栏图标自动隐藏（默认不隐藏；到时只藏图标，记录 / 面板 / 刻度保留）。

/// 顶栏的返回 / 前进按钮（[FushiFloatingTopBar.actions] 里单独成一组，放最前）。
///
/// [backLabel] / [forwardLabel] 是落点的位置文案（百分比 / 时间 / 页码），只进
/// tooltip；null 表示那一侧没有历史、按钮不出现。两侧都为 null 返回空表。
List<FushiToolbarItem> jumpHistoryToolbarItems({
  required String? backLabel,
  required String? forwardLabel,
  required VoidCallback onBack,
  required VoidCallback onForward,
  required VoidCallback onOpenPanel,
}) {
  final String? back = backLabel;
  final String? forward = forwardLabel;
  return <FushiToolbarItem>[
    if (back != null)
      FushiToolbarItem(
        key: const ValueKey<String>('fushi_jump_back'),
        icon: FushiIcons.undo,
        label: t.media_jump_history_back,
        tooltip:
            '${t.media_jump_back(position: back)}\n'
            '${t.media_jump_history_open_hint}',
        emphasized: true,
        onPressed: onBack,
        onLongPress: onOpenPanel,
      ),
    if (forward != null)
      FushiToolbarItem(
        key: const ValueKey<String>('fushi_jump_forward'),
        icon: FushiIcons.redo,
        label: t.media_jump_history_forward,
        tooltip:
            '${t.media_jump_forward(position: forward)}\n'
            '${t.media_jump_history_open_hint}',
        emphasized: true,
        onPressed: onForward,
        onLongPress: onOpenPanel,
      ),
  ];
}

/// 「⋯」溢出菜单里的「跳转记录」入口（顶栏图标被关掉 / 自动隐藏后仍能打开面板）。
FushiToolbarItem jumpHistoryPanelMenuItem({required VoidCallback onOpen}) =>
    FushiToolbarItem(
      key: const ValueKey<String>('fushi_jump_history_menu'),
      icon: FushiIcons.history,
      label: t.media_jump_history_title,
      onPressed: onOpen,
    );

/// 不走 [FushiFloatingTopBar] 的自绘顶栏用的同款按钮行（视频控制条等）。与
/// [jumpHistoryToolbarItems] 同一份按钮定义，外观由 [FushiToolbarButton] 统一。
class FushiJumpHistoryActions extends StatelessWidget {
  const FushiJumpHistoryActions({
    super.key,
    required this.items,
    this.colors,
    this.iconSize = 24,
  });

  final List<FushiToolbarItem> items;
  final FushiFloatingToolbarColors? colors;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(context, colors: colors);
    return ExcludeFocus(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final FushiToolbarItem item in items)
            FushiToolbarButton(
              item: item,
              foreground: palette.foreground,
              selectedContainer: palette.selectedContainer,
              selectedForeground: palette.selectedForeground,
              iconSize: iconSize,
            ),
        ],
      ),
    );
  }
}

/// 顶栏图标此刻该不该画：设置开着、有历史、没过自动隐藏时限。
bool jumpHistoryToolbarVisible({
  required bool enabled,
  required bool hasHistory,
  required bool expired,
}) => enabled && hasHistory && !expired;

/// 「跳转记录」三项设置的一份快照（顶栏图标开关、刻度开关、自动隐藏秒数）。
@immutable
class JumpHistoryPrefs {
  const JumpHistoryPrefs({
    required this.toolbar,
    required this.progressMarks,
    required this.autoHideSeconds,
  });

  /// 从偏好仓库读当前值。
  factory JumpHistoryPrefs.of(PreferencesRepository prefs) => JumpHistoryPrefs(
    toolbar: prefs.jumpHistoryToolbar,
    progressMarks: prefs.jumpHistoryProgressMarks,
    autoHideSeconds: prefs.jumpHistoryAutoHideSeconds,
  );

  final bool toolbar;
  final bool progressMarks;

  /// 0 = 不自动隐藏。
  final int autoHideSeconds;

  @override
  bool operator ==(Object other) =>
      other is JumpHistoryPrefs &&
      other.toolbar == toolbar &&
      other.progressMarks == progressMarks &&
      other.autoHideSeconds == autoHideSeconds;

  @override
  int get hashCode => Object.hash(toolbar, progressMarks, autoHideSeconds);
}

/// 只在「跳转记录」三项设置变化时才通知的偏好选择器：订阅 [source]（偏好仓库，
/// 写任何偏好都会通知），每次重读 [read]，值真的变了才 notify——页面把它并进
/// 顶栏 / 刻度的重建源，设置一改图标与刻度立刻跟上，写别的偏好不连带重建。
class JumpHistoryPrefsListenable extends ChangeNotifier
    implements ValueListenable<JumpHistoryPrefs> {
  JumpHistoryPrefsListenable({
    required Listenable source,
    required JumpHistoryPrefs Function() read,
  }) : _source = source,
       _read = read,
       _value = read() {
    _source.addListener(_onSourceChanged);
  }

  /// 订阅 [prefs] 本身（它是 ChangeNotifier，`setJumpHistory*` 写完会通知）。
  factory JumpHistoryPrefsListenable.fromRepository(
    PreferencesRepository prefs,
  ) => JumpHistoryPrefsListenable(
    source: prefs,
    read: () => JumpHistoryPrefs.of(prefs),
  );

  final Listenable _source;
  final JumpHistoryPrefs Function() _read;
  JumpHistoryPrefs _value;

  @override
  JumpHistoryPrefs get value => _value;

  void _onSourceChanged() {
    final JumpHistoryPrefs next = _read();
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _source.removeListener(_onSourceChanged);
    super.dispose();
  }
}

/// 顶栏图标的自动隐藏计时：每次跳转 / 返回 / 前进调 [markJump]，过了设置的秒数后
/// [expired] 变 true 并通知一次（页面据此重建、图标收起）。只管图标，不碰历史。
///
/// 过期状态只有一个来源：计时器到点置位的 [expired] 标志（不在重建时拿墙钟重算，
/// 墙钟回拨 / 计时器比墙钟差值早到几毫秒都不会让图标卡住不藏）。距上次跳转的时长
/// 用单调的 [Stopwatch] 量；页面开着时改了时长（[prefs] 通知），按「已过去的单调
/// 时长」重新安排或取消计时器：改成不隐藏 = 取消并让图标回来，改成 N 秒 = 剩余
/// 时长到点再藏（已超过则立即藏）。
class JumpHistoryAutoHide extends ChangeNotifier {
  /// [stopwatch] 只给测试注入假时钟的秒表（默认真 [Stopwatch]）。
  JumpHistoryAutoHide({
    required ValueListenable<JumpHistoryPrefs> prefs,
    Stopwatch Function()? stopwatch,
  }) : _prefs = prefs,
       _newStopwatch = stopwatch ?? Stopwatch.new,
       _seconds = prefs.value.autoHideSeconds {
    _prefs.addListener(_onPrefsChanged);
  }

  final ValueListenable<JumpHistoryPrefs> _prefs;
  final Stopwatch Function() _newStopwatch;
  int _seconds;

  /// 自上次跳转起的单调计时；null = 还没跳转过（或已 [reset]）。
  Stopwatch? _sinceJump;
  Timer? _timer;
  bool _expired = false;

  /// 图标是否已到时收起。
  bool get expired => _expired;

  /// 刚发生一次跳转（含返回 / 前进 / 面板跳转）：重新计时，图标重新出现。
  void markJump() {
    _sinceJump = _newStopwatch()..start();
    _expired = false;
    _schedule();
    notifyListeners();
  }

  /// 历史被清空 / 换了作用域（换集）：停表。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _sinceJump = null;
    _expired = false;
    notifyListeners();
  }

  /// 按当前时长与已过去的单调时长（重新）安排计时器；已到时直接置位。
  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final Stopwatch? since = _sinceJump;
    if (since == null || _seconds <= 0) {
      _expired = false;
      return;
    }
    final Duration remaining = Duration(seconds: _seconds) - since.elapsed;
    if (remaining <= Duration.zero) {
      _expired = true;
      return;
    }
    _expired = false;
    _timer = Timer(remaining, _expire);
  }

  void _expire() {
    _timer = null;
    if (_expired) return;
    _expired = true;
    notifyListeners();
  }

  void _onPrefsChanged() {
    final int seconds = _prefs.value.autoHideSeconds;
    if (seconds == _seconds) return;
    _seconds = seconds;
    final bool before = _expired;
    _schedule();
    if (_expired != before) notifyListeners();
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    _timer?.cancel();
    super.dispose();
  }
}

/// 来源动作的面板文案。
String jumpSourceLabel(JumpSource source) => switch (source) {
  JumpSource.tableOfContents => t.media_jump_history_source_table_of_contents,
  JumpSource.link => t.media_jump_history_source_link,
  JumpSource.search => t.media_jump_history_source_search,
  JumpSource.favorite => t.media_jump_history_source_favorite,
  JumpSource.positionJump => t.media_jump_history_source_position_jump,
  JumpSource.gallery => t.media_jump_history_source_gallery,
  JumpSource.progressBar => t.media_jump_history_source_progress_bar,
  JumpSource.cue => t.media_jump_history_source_cue,
  JumpSource.chapter => t.media_jump_history_source_chapter,
  JumpSource.pageDialog => t.media_jump_history_source_page_dialog,
  JumpSource.restart => t.media_jump_history_source_restart,
  JumpSource.lookup => t.media_jump_history_source_lookup,
  JumpSource.remote => t.media_jump_history_source_remote,
};

/// 「刚刚 / N 分钟前 / N 小时前 / N 天前」（复用 activity_* 文案）。
String jumpHistoryRelativeTime(DateTime at, DateTime now) {
  final Duration d = now.difference(at);
  if (d.inMinutes < 1) return t.activity_just_now;
  if (d.inHours < 1) return t.activity_minutes_ago(n: d.inMinutes);
  if (d.inDays < 1) return t.activity_hours_ago(n: d.inHours);
  return t.activity_days_ago(n: d.inDays);
}

/// 面板里的一行（纯数据，便于测试）：[steps] < 0 = 往回走几步，> 0 = 往前走几步，
/// 0 = 当前位置。
@immutable
class JumpHistoryPanelRow<T> {
  const JumpHistoryPanelRow({
    required this.steps,
    required this.point,
    this.at,
    this.source,
  });

  final int steps;

  /// 当前位置那一行为 null（由宿主给文案）。
  final T? point;
  final DateTime? at;
  final JumpSource? source;
}

/// 面板的行序（浏览器历史式，由新到旧）：前进栈最远的在最上，然后是当前位置，再往下
/// 是后退栈由近到远。
List<JumpHistoryPanelRow<T>> jumpHistoryPanelRows<T>(JumpHistory<T> history) {
  final List<JumpHistoryEntry<T>> forward = history.forwardEntries;
  final List<JumpHistoryEntry<T>> back = history.backEntries;
  return <JumpHistoryPanelRow<T>>[
    for (int i = 0; i < forward.length; i++)
      JumpHistoryPanelRow<T>(
        steps: forward.length - i,
        point: forward[i].point,
        at: forward[i].at,
        source: forward[i].source,
      ),
    JumpHistoryPanelRow<T>(steps: 0, point: null),
    for (int j = back.length - 1; j >= 0; j--)
      JumpHistoryPanelRow<T>(
        steps: -(back.length - j),
        point: back[j].point,
        at: back[j].at,
        source: back[j].source,
      ),
  ];
}

/// 打开「跳转记录」面板（宽屏右侧侧板 / 窄窗底部 sheet）。点某一行先关面板再
/// 调 [onWalk]（步数语义见 [JumpHistoryPanelRow.steps]，宿主用
/// [JumpHistory.goBackSteps] / [JumpHistory.goForwardSteps] 落地）；「清除」调
/// [onClear] 并关面板。
Future<void> showJumpHistoryPanel<T>({
  required BuildContext context,
  required JumpHistory<T> history,
  required String Function(T point) labelOf,
  required String currentLabel,
  required void Function(int steps) onWalk,
  required VoidCallback onClear,
}) => showReaderSideSheet<void>(
  context: context,
  side: ReaderSideSheetSide.right,
  bottomSheetWhenCompact: true,
  builder: (BuildContext sheetContext) => FushiJumpHistoryPanel<T>(
    rows: jumpHistoryPanelRows<T>(history),
    labelOf: labelOf,
    currentLabel: currentLabel,
    now: DateTime.now(),
    onWalk: (int steps) {
      Navigator.of(sheetContext).pop();
      onWalk(steps);
    },
    onClear: () {
      Navigator.of(sheetContext).pop();
      onClear();
    },
    onClose: () => Navigator.of(sheetContext).maybePop(),
  ),
);

class FushiJumpHistoryPanel<T> extends StatelessWidget {
  const FushiJumpHistoryPanel({
    super.key,
    required this.rows,
    required this.labelOf,
    required this.currentLabel,
    required this.now,
    required this.onWalk,
    required this.onClear,
    required this.onClose,
  });

  final List<JumpHistoryPanelRow<T>> rows;
  final String Function(T point) labelOf;
  final String currentLabel;
  final DateTime now;
  final void Function(int steps) onWalk;
  final VoidCallback onClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bool empty = rows.length <= 1;
    return ReaderSideSheet(
      title: t.media_jump_history_title,
      icon: FushiIcons.history,
      onClose: onClose,
      headerActions: <Widget>[
        if (!empty)
          FushiTextButton(
            key: const ValueKey<String>('fushi_jump_history_clear'),
            onPressed: onClear,
            child: Text(t.media_jump_history_clear_short),
          ),
      ],
      child: empty
          ? ReaderPanelEmpty(
              icon: FushiIcons.history,
              message: t.media_jump_history_empty,
            )
          : FushiEntranceScope(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < rows.length; i++)
                    FushiStaggeredEntrance(index: i, child: _row(rows[i])),
                ],
              ),
            ),
    );
  }

  Widget _row(JumpHistoryPanelRow<T> row) {
    final T? point = row.point;
    if (row.steps == 0 || point == null) {
      return FushiListItem(
        key: const ValueKey<String>('fushi_jump_history_row_current'),
        selected: true,
        leading: const FushiIcon(FushiIcons.history),
        title: Text(t.media_jump_history_current),
        subtitle: Text(currentLabel),
      );
    }
    final DateTime? at = row.at;
    final JumpSource? source = row.source;
    final String subtitle = <String>[
      if (source != null) jumpSourceLabel(source),
      if (at != null) jumpHistoryRelativeTime(at, now),
    ].join(' · ');
    return FushiListItem(
      key: ValueKey<String>('fushi_jump_history_row_${row.steps}'),
      leading: FushiIcon(row.steps < 0 ? FushiIcons.undo : FushiIcons.redo),
      title: Text(labelOf(point)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: () => onWalk(row.steps),
    );
  }
}

/// 进度条刻度用的落点（0..1）。[fractionOf] 返回 null 的点（不在这条进度轴上，如
/// 漫画跨话的点）不画。
({List<double> back, List<double> forward}) jumpHistoryMarkFractions<T>(
  JumpHistory<T> history,
  double? Function(T point) fractionOf,
) {
  List<double> collect(List<JumpHistoryEntry<T>> entries) => <double>[
    for (final JumpHistoryEntry<T> e in entries)
      if (fractionOf(e.point) case final double f when f.isFinite)
        f.clamp(0.0, 1.0),
  ];
  return (
    back: collect(history.backEntries),
    forward: collect(history.forwardEntries),
  );
}

/// 进度条 / 页码滑块上的跳转落点刻度：返回点 = tertiary，前进点 = secondary，
/// 各描一圈 surface 细边保证压在已播放填充上也看得见。只看不点（[IgnorePointer]，
/// 免得误触 seek）。叠在进度轨道正上方、与轨道同宽的盒子里，竖直居中。
class FushiJumpProgressMarks extends StatelessWidget {
  const FushiJumpProgressMarks({
    super.key,
    required this.back,
    required this.forward,
    this.tickWidth = 3,
    this.tickHeight = 14,
  });

  final List<double> back;
  final List<double> forward;
  final double tickWidth;
  final double tickHeight;

  @override
  Widget build(BuildContext context) {
    if (back.isEmpty && forward.isEmpty) return const SizedBox.shrink();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.enter,
        builder: (BuildContext context, double v, Widget? child) =>
            Opacity(opacity: v.clamp(0.0, 1.0), child: child),
        child: CustomPaint(
          key: const ValueKey<String>('fushi_jump_progress_marks'),
          size: Size.infinite,
          painter: JumpProgressMarksPainter(
            back: back,
            forward: forward,
            backColor: scheme.tertiary,
            forwardColor: scheme.secondary,
            haloColor: scheme.surface,
            tickWidth: tickWidth,
            tickHeight: tickHeight,
          ),
        ),
      ),
    );
  }
}

class JumpProgressMarksPainter extends CustomPainter {
  JumpProgressMarksPainter({
    required this.back,
    required this.forward,
    required this.backColor,
    required this.forwardColor,
    required this.haloColor,
    required this.tickWidth,
    required this.tickHeight,
  });

  final List<double> back;
  final List<double> forward;
  final Color backColor;
  final Color forwardColor;
  final Color haloColor;
  final double tickWidth;
  final double tickHeight;

  /// 某个落点刻度的矩形（纯几何，测试用）。
  static Rect tickRect(
    Size size,
    double fraction, {
    required double tickWidth,
    required double tickHeight,
  }) {
    final double x = (fraction.clamp(0.0, 1.0)) * size.width;
    final double h = tickHeight.clamp(0.0, size.height);
    return Rect.fromCenter(
      center: Offset(x, size.height / 2),
      width: tickWidth,
      height: h,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    void draw(List<double> fractions, Color color) {
      final Paint halo = Paint()..color = haloColor;
      final Paint fill = Paint()..color = color;
      for (final double f in fractions) {
        final Rect r = tickRect(
          size,
          f,
          tickWidth: tickWidth,
          tickHeight: tickHeight,
        );
        final Radius radius = Radius.circular(tickWidth / 2);
        canvas.drawRRect(RRect.fromRectAndRadius(r.inflate(1), radius), halo);
        canvas.drawRRect(RRect.fromRectAndRadius(r, radius), fill);
      }
    }

    draw(back, backColor);
    draw(forward, forwardColor);
  }

  @override
  bool shouldRepaint(JumpProgressMarksPainter old) =>
      !listEquals(old.back, back) ||
      !listEquals(old.forward, forward) ||
      old.backColor != backColor ||
      old.forwardColor != forwardColor ||
      old.haloColor != haloColor ||
      old.tickWidth != tickWidth ||
      old.tickHeight != tickHeight;
}
