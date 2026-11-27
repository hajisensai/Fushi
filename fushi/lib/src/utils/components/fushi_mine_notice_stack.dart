/// 制卡结果卡的**队列与叠放**：底部 toast 与视频页 OSD 共用（视频页禁止 import
/// toast，BUG-931，所以这一层不依赖 toast）。
///
/// 用户 2026-11-22 重设计：
/// * **处理中 → 结果原地变形**：结果到来时替换掉对应的「制卡中」那一张（同词优先，
///   否则最近的一张），不再弹第二张、位置也不跳；
/// * **连续制卡叠起来**：后台制卡 / 批量制卡几秒内出好几张结果，新卡压在最上面，
///   旧卡在后面露出一条边（最多两层），右上角是张数；悬停 / 点张数 / 键盘聚焦展开
///   成列表。此前一张顶掉一张，失败卡会被随后的成功卡顶掉看不到；
/// * **停留按严重程度分档**（[mineNoticeDwell]），悬停 / 聚焦时暂停；失败卡展开
///   详情后不再自动收起。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// 一条制卡结果通知的内容（不含计时与展开态）。
@immutable
class MineNotice {
  const MineNotice({
    required this.status,
    required this.message,
    this.term,
    this.reading,
    this.detail,
    this.action,
  });

  final MineToastStatus status;
  final String message;
  final String? term;
  final String? reading;
  final String? detail;
  final MineNoticeAction? action;
}

/// 队列里的一张卡：[id] 在原地变形时不变（卡片 widget 靠它保住状态做过渡）。
final class MineNoticeEntry {
  MineNoticeEntry._(this.id, this.notice);

  final int id;
  MineNotice notice;
  bool expanded = false;

  Duration get dwell =>
      mineNoticeDwell(notice.status, hasAction: notice.action != null);

  Timer? _timer;
  Duration _remaining = Duration.zero;
  DateTime? _startedAt;
}

/// 制卡结果队列：最新在前。每张卡各自计时，[paused] 时全部停表（悬停 / 聚焦），
/// 展开详情的卡不计时。
class MineNoticeController extends ChangeNotifier {
  MineNoticeController({this.maxEntries = 5});

  /// 最多留几张；再多就丢最旧的非失败卡（失败卡要等用户看到）。
  final int maxEntries;

  final List<MineNoticeEntry> _entries = <MineNoticeEntry>[];
  int _nextId = 0;
  bool _paused = false;
  bool _disposed = false;

  List<MineNoticeEntry> get entries =>
      List<MineNoticeEntry>.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  bool get paused => _paused;

  /// 显示一条结果。非「处理中」的结果优先替换一张正在「处理中」的卡（同词优先，
  /// 否则最近的那张）——同一张卡原地变成结果。返回这张卡的 id。
  int show(MineNotice notice) {
    MineNoticeEntry? target;
    if (notice.status != MineToastStatus.pending) {
      final Iterable<MineNoticeEntry> pending = _entries.where(
        (MineNoticeEntry e) => e.notice.status == MineToastStatus.pending,
      );
      final String? term = notice.term;
      target =
          pending
              .where(
                (MineNoticeEntry e) => term != null && e.notice.term == term,
              )
              .firstOrNull ??
          pending.firstOrNull;
    }
    if (target != null) {
      target.notice = MineNotice(
        status: notice.status,
        message: notice.message,
        // 结果没带词时沿用「制卡中」那张的词（同一张卡）。
        term: notice.term ?? target.notice.term,
        reading: notice.reading ?? target.notice.reading,
        detail: notice.detail,
        action: notice.action,
      );
      target.expanded = false;
      _startTimer(target, target.dwell);
    } else {
      target = MineNoticeEntry._(_nextId++, notice);
      _entries.insert(0, target);
      _startTimer(target, target.dwell);
      _trim();
    }
    notifyListeners();
    return target.id;
  }

  void dismiss(int id) {
    final int index = _entries.indexWhere((MineNoticeEntry e) => e.id == id);
    if (index < 0) return;
    _entries.removeAt(index)._timer?.cancel();
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    for (final MineNoticeEntry e in _entries) {
      e._timer?.cancel();
    }
    _entries.clear();
    notifyListeners();
  }

  /// 悬停 / 键盘聚焦在卡上：全部停表；离开时各卡从剩余时长接着走。
  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    for (final MineNoticeEntry e in _entries) {
      if (value) {
        _pause(e);
      } else if (!e.expanded) {
        _startTimer(e, e._remaining);
      }
    }
    notifyListeners();
  }

  /// 展开 / 收起一张卡的详情：展开期间不自动收起，收起后按完整停留时长重新计时。
  void setExpanded(int id, bool expanded) {
    final MineNoticeEntry? e = _entries
        .where((MineNoticeEntry e) => e.id == id)
        .firstOrNull;
    if (e == null || e.expanded == expanded) return;
    e.expanded = expanded;
    if (expanded) {
      e._timer?.cancel();
      e._timer = null;
    } else {
      _startTimer(e, e.dwell);
    }
    notifyListeners();
  }

  void _startTimer(MineNoticeEntry e, Duration duration) {
    e._timer?.cancel();
    e._remaining = duration;
    if (_paused || e.expanded) {
      e._timer = null;
      e._startedAt = null;
      return;
    }
    e._startedAt = DateTime.now();
    e._timer = Timer(duration, () => dismiss(e.id));
  }

  void _pause(MineNoticeEntry e) {
    final DateTime? started = e._startedAt;
    if (started != null) {
      final Duration left = e._remaining - DateTime.now().difference(started);
      e._remaining = left.isNegative ? Duration.zero : left;
    }
    e._timer?.cancel();
    e._timer = null;
    e._startedAt = null;
  }

  void _trim() {
    while (_entries.length > maxEntries) {
      final int victim = _entries.lastIndexWhere(
        (MineNoticeEntry e) => e.notice.status != MineToastStatus.failed,
      );
      final int index = victim >= 0 ? victim : _entries.length - 1;
      _entries.removeAt(index)._timer?.cancel();
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final MineNoticeEntry e in _entries) {
      e._timer?.cancel();
    }
    _entries.clear();
    super.dispose();
  }
}

/// 叠放方向：卡片锚在屏幕底部（toast）时旧卡露在上方，锚在顶部（视频 OSD）时
/// 露在下方——总是朝屏幕内侧。
enum MineNoticeStackAnchor { top, bottom }

/// 把 [MineNoticeController] 画出来：收起态 = 最新一张 + 后面露边的两层 + 张数；
/// 展开态 = 全部卡片的列表。动作按钮点下先收起那张卡再执行。
class FushiMineNoticeStack extends StatefulWidget {
  const FushiMineNoticeStack({
    super.key,
    required this.controller,
    this.anchor = MineNoticeStackAnchor.bottom,
    this.compact = false,
    this.maxWidth = 440,
  });

  final MineNoticeController controller;
  final MineNoticeStackAnchor anchor;
  final bool compact;
  final double maxWidth;

  @override
  State<FushiMineNoticeStack> createState() => _FushiMineNoticeStackState();
}

/// 露边：每层往外错开多少、两侧各收进多少。
const double _kPeekStep = 8;
const double _kPeekInset = 14;
const int _kMaxPeeks = 2;

/// 计数徽标的命中方块边长：视觉 24 的徽标居中其中，方块中心压在最前那张卡的右上角。
const double _kBadgeHit = 36;

class _FushiMineNoticeStackState extends State<FushiMineNoticeStack>
    with StateResourceScope<FushiMineNoticeStack> {
  bool _hovering = false;
  bool _focused = false;
  bool _pinnedOpen = false;

  MineNoticeController get _c => widget.controller;

  void _syncPause() {
    _c.paused =
        _hovering ||
        _focused ||
        _pinnedOpen ||
        _c.entries.any((MineNoticeEntry e) => e.expanded);
  }

  @override
  void initState() {
    super.initState();
    listenTo(_c, _onChanged, slot: #controller);
  }

  @override
  void didUpdateWidget(FushiMineNoticeStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      listenTo(widget.controller, _onChanged, slot: #controller);
    }
  }

  void _onChanged() {
    if (!mounted) return;
    // 只剩一张时展开没有意义，收回。
    if (_c.entries.length <= 1) _pinnedOpen = false;
    setState(() {});
  }

  MineNoticeAction? _wrapAction(MineNoticeEntry e) {
    final MineNoticeAction? action = e.notice.action;
    if (action == null) return null;
    return MineNoticeAction(
      label: action.label,
      onPressed: () {
        _c.dismiss(e.id);
        action.onPressed();
      },
    );
  }

  Widget _card(MineNoticeEntry e) => FushiMineNoticeCard(
    key: ValueKey<int>(e.id),
    status: e.notice.status,
    message: e.notice.message,
    term: e.notice.term,
    reading: e.notice.reading,
    detail: e.notice.detail,
    action: _wrapAction(e),
    visibleFor: e.dwell,
    compact: widget.compact,
    maxWidth: widget.maxWidth,
    paused: _c.paused || e.expanded,
    expanded: e.expanded,
    onExpandedChanged: (bool v) {
      _c.setExpanded(e.id, v);
      _syncPause();
    },
    onDismiss: () {
      _c.dismiss(e.id);
      _syncPause();
    },
  );

  @override
  Widget build(BuildContext context) {
    final List<MineNoticeEntry> entries = _c.entries;
    if (entries.isEmpty) return const SizedBox.shrink();
    final bool expanded = entries.length > 1 && (_hovering || _pinnedOpen);
    final bool motion = fushiMotionEnabled(context);
    final Widget content = expanded
        ? _buildList(context, entries)
        : _buildCollapsed(context, entries);
    return MouseRegion(
      onEnter: (_) {
        _hovering = true;
        _syncPause();
        setState(() {});
      },
      onExit: (_) {
        _hovering = false;
        _syncPause();
        setState(() {});
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (bool focused) {
          _focused = focused;
          _syncPause();
        },
        child: FushiAnimatedSize(
          duration: motion ? FushiMotion.medium : Duration.zero,
          curve: FushiMotion.standard,
          // 卡片贴在起始侧（左下 / 视频左上，RTL 镜像）：展开 / 收起时起始边不动
          // （反馈 RZpvO4Dl3y）。
          alignment: widget.anchor == MineNoticeStackAnchor.bottom
              ? AlignmentDirectional.bottomStart
              : AlignmentDirectional.topStart,
          child: content,
        ),
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context, List<MineNoticeEntry> entries) {
    final MineNoticeEntry front = entries.first;
    final int peeks = (entries.length - 1).clamp(0, _kMaxPeeks);
    final bool bottom = widget.anchor == MineNoticeStackAnchor.bottom;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool eink = isEinkTheme(context);
    final bool motion = fushiMotionEnabled(context);
    final Widget frontCard = AnimatedSwitcher(
      duration: motion ? FushiMotion.medium : Duration.zero,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: bottom
            ? AlignmentDirectional.bottomStart
            : AlignmentDirectional.topStart,
        children: <Widget>[...previous, ?current],
      ),
      child: _card(front),
    );
    final bool stacked = entries.length > 1;
    // 叠放时给徽标在右上留出半个命中方块：徽标整个落在本组件的布局盒里。伸出父盒
    // 的部分 Flutter 不做命中测试，压在卡角外的半边原本点不中。
    const double reserve = _kBadgeHit / 2;
    final double peekTop = bottom ? _kPeekStep * peeks : 0;
    final Widget cards = Padding(
      padding: EdgeInsets.only(
        top: peekTop + (stacked ? reserve : 0),
        bottom: bottom ? 0 : _kPeekStep * peeks,
        right: stacked ? reserve : 0,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // 后面露边的旧卡：只画底色块（同尺寸，错开 + 收窄），内容不画。
          for (int k = peeks; k >= 1; k--)
            Positioned(
              left: _kPeekInset * k,
              right: _kPeekInset * k,
              top: bottom ? -_kPeekStep * k : _kPeekStep * k,
              bottom: bottom ? _kPeekStep * k : -_kPeekStep * k,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: eink
                        ? Colors.white
                        : mineNoticeTone(
                            entries[k].notice.status,
                            dark: dark,
                          ).container,
                    border: eink ? Border.all(width: 1.5) : null,
                    borderRadius: BorderRadius.all(
                      Radius.circular(widget.compact ? 18 : 22),
                    ),
                    boxShadow: eink
                        ? null
                        : const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x26000000),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                  ),
                ),
              ),
            ),
          frontCard,
        ],
      ),
    );
    if (!stacked) return cards;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        cards,
        Positioned(
          right: 0,
          top: peekTop,
          child: _CountBadge(
            count: entries.length,
            onPressed: () {
              setState(() => _pinnedOpen = true);
              _syncPause();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<MineNoticeEntry> entries) {
    final bool bottom = widget.anchor == MineNoticeStackAnchor.bottom;
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    // Apple 不认 MD3 色调容器：头条与通知卡同一块白 / 深灰实底、系统 label 色。
    final FushiAppleColors? apple =
        isGlassDesign(context) && !isEinkTheme(context)
        ? appleColorsOf(context)
        : null;
    final int failed = entries
        .where((MineNoticeEntry e) => e.notice.status == MineToastStatus.failed)
        .length;
    final Widget header = Container(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
      decoration: BoxDecoration(
        color: apple != null
            ? mineNoticeAppleContainer(dark: cs.brightness == Brightness.dark)
            : cs.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              failed > 0
                  ? t.card_notice_stack_summary_failed(
                      n: entries.length,
                      failed: failed,
                    )
                  : t.card_notice_stack_summary(n: entries.length),
              style: type.labelLarge.copyWith(
                color: apple?.label ?? cs.onSurface,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          FushiTextButton(
            key: const ValueKey<String>('mine-notice-stack-collapse'),
            onPressed: () {
              setState(() {
                _pinnedOpen = false;
                _hovering = false;
              });
              _syncPause();
            },
            child: Text(t.card_notice_hide),
          ),
        ],
      ),
    );
    // 最新的一张始终贴着锚边（底部锚定时在最下面），列表朝屏幕内侧长。
    final List<Widget> cards = <Widget>[
      for (final MineNoticeEntry e in entries)
        Padding(padding: const EdgeInsets.only(top: 8), child: _card(e)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: bottom
          ? <Widget>[header, ...cards.reversed]
          : <Widget>[header, ...cards],
    );
  }
}

/// 收起态右上角的张数：点开展开成列表（键盘可达）。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    return Semantics(
      button: true,
      label: t.card_notice_stack_badge(n: count),
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey<String>('mine-notice-stack-badge'),
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: _kBadgeHit,
            child: Center(
              child: Container(
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: eink ? Colors.black : cs.inverseSurface,
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  '$count',
                  style: context.fushiType.labelMedium.copyWith(
                    color: eink ? Colors.white : cs.onInverseSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
