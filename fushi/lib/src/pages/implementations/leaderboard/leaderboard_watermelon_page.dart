// 「超级大西瓜」：本周字数榜（前 100 名）画成一堆头像球，字数越多球越大，
// 像合成大西瓜那样静止堆在一起。几何只算一次（见 leaderboard_watermelon_layout），
// 不跑物理；整堆可双指缩放 / 拖动平移，点球进该用户主页。

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_watermelon_layout.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_user_page.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 一次取多少人（服务端单页上限 100）。
const int kWatermelonRankLimit = 100;

/// 大西瓜页。[rows] 非空时直接用（测试 / 已取到的数据），否则自己取本周字数榜。
class LeaderboardWatermelonPage extends ConsumerStatefulWidget {
  const LeaderboardWatermelonPage({this.rows, this.selfId, super.key});

  final List<RankRow>? rows;
  final String? selfId;

  @override
  ConsumerState<LeaderboardWatermelonPage> createState() =>
      _LeaderboardWatermelonPageState();
}

class _LeaderboardWatermelonPageState
    extends ConsumerState<LeaderboardWatermelonPage> {
  final GlobalKey<_WatermelonCanvasState> _canvas =
      GlobalKey<_WatermelonCanvasState>();
  List<RankRow>? _rows;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _rows = widget.rows;
    if (_rows == null) unawaited(_load());
  }

  Future<void> _load() async {
    final LeaderboardClient? client = ref
        .read(leaderboardServiceProvider)
        .client;
    if (client == null) return;
    setState(() => _error = null);
    try {
      final RankPage page = await client.rank(
        metric: LeaderboardMetric.chars,
        window: LeaderboardWindow.week,
        limit: kWatermelonRankLimit,
      );
      if (mounted) setState(() => _rows = page.rows);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.watermelon', e, st);
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? selfId =
        widget.selfId ?? ref.watch(leaderboardServiceProvider).self?.account.id;
    final List<RankRow>? rows = _rows;
    final Widget body;
    if (_error != null) {
      body = SafeArea(
        bottom: false,
        child: LeaderboardErrorView(
          error: _error!,
          onRetry: () => unawaited(_load()),
        ),
      );
    } else if (rows == null) {
      body = const SafeArea(bottom: false, child: FushiLoadingView());
    } else if (rows.where((RankRow r) => r.value > 0).isEmpty) {
      body = SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: FushiIcons.statistics,
          message: t.leaderboard_board_empty,
        ),
      );
    } else {
      body = _WatermelonCanvas(
        key: _canvas,
        rows: rows.where((RankRow r) => r.value > 0).toList(),
        selfId: selfId,
      );
    }
    return FushiPageScaffold(
      title: t.leaderboard_watermelon_title,
      subtitle: t.leaderboard_watermelon_subtitle,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('leaderboard-watermelon-fit'),
          icon: FushiIcons.fullscreen,
          tooltip: t.leaderboard_watermelon_fit,
          onTap: () => _canvas.currentState?.fit(animate: true),
        ),
      ],
      body: body,
    );
  }
}

class _WatermelonCanvas extends StatefulWidget {
  const _WatermelonCanvas({required this.rows, this.selfId, super.key});

  final List<RankRow> rows;
  final String? selfId;

  @override
  State<_WatermelonCanvas> createState() => _WatermelonCanvasState();
}

class _WatermelonCanvasState extends State<_WatermelonCanvas>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _fitAnim = AnimationController(vsync: this);
  Animation<Matrix4>? _fitTween;
  late WatermelonPile _pile;
  Size? _viewport;
  EdgeInsets _insets = EdgeInsets.zero;

  @override
  void initState() {
    super.initState();
    _pile = _layout(widget.rows, _aspect);
    _fitAnim.addListener(() {
      final Animation<Matrix4>? tween = _fitTween;
      if (tween != null) _transform.value = tween.value;
    });
  }

  @override
  void didUpdateWidget(_WatermelonCanvas old) {
    super.didUpdateWidget(old);
    if (!identical(old.rows, widget.rows)) {
      _pile = _layout(widget.rows, _aspect);
      WidgetsBinding.instance.addPostFrameCallback((_) => fit());
    }
  }

  @override
  void dispose() {
    _fitAnim.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// 视口可用区的宽高比：堆的形状跟着它（手机竖屏堆高、桌面摊宽）。
  double _aspect = 1;

  static WatermelonPile _layout(List<RankRow> rows, double aspect) {
    final int maxValue = rows.fold<int>(
      0,
      (int m, RankRow r) => math.max(m, r.value),
    );
    // 名次即从大到小：大球先落、垫在底下。
    return layoutWatermelonPile(<double>[
      for (final RankRow r in rows) watermelonRadius(r.value, maxValue),
    ], aspect: aspect);
  }

  /// 整堆缩放到视口内居中（留出页头与安全区）。
  Matrix4 _fitMatrix() {
    final Size? viewport = _viewport;
    if (viewport == null || _pile.width <= 0) return Matrix4.identity();
    const double margin = 16;
    final double availW = viewport.width - _insets.horizontal - margin * 2;
    final double availH = viewport.height - _insets.vertical - margin * 2;
    final double scale = math.max(
      0.05,
      math.min(availW / _pile.width, availH / _pile.height),
    );
    final double dx =
        _insets.left + margin + (availW - _pile.width * scale) / 2;
    final double dy =
        _insets.top + margin + (availH - _pile.height * scale) / 2;
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  static double _viewportAspect(Size viewport, EdgeInsets insets) {
    final double w = viewport.width - insets.horizontal;
    final double h = viewport.height - insets.vertical;
    if (w <= 0 || h <= 0) return 1;
    return (w / h).clamp(0.4, 2.5);
  }

  void fit({bool animate = false}) {
    if (!mounted) return;
    final Matrix4 target = _fitMatrix();
    final Duration d = animate
        ? fushiMotionDuration(context, FushiMotion.medium)
        : Duration.zero;
    if (d == Duration.zero) {
      _transform.value = target;
      return;
    }
    _fitTween = Matrix4Tween(
      begin: _transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _fitAnim, curve: FushiMotion.standard));
    _fitAnim
      ..duration = d
      ..forward(from: 0);
  }

  void _openUser(String id) => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => LeaderboardUserPage(accountId: id),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final EdgeInsets insets = EdgeInsets.only(
      top: media.padding.top,
      bottom: media.padding.bottom,
      left: media.padding.left,
      right: media.padding.right,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = constraints.biggest;
        if (_viewport != viewport || _insets != insets) {
          final bool first = _viewport == null;
          _viewport = viewport;
          _insets = insets;
          final double aspect = _viewportAspect(viewport, insets);
          // 宽高比明显变了（转屏 / 拉窗口）才重排，避免拖动窗口时逐帧重算。
          if ((aspect / _aspect - 1).abs() > 0.15) {
            _aspect = aspect;
            _pile = _layout(widget.rows, _aspect);
          }
          if (first) {
            _transform.value = _fitMatrix();
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) => fit());
          }
        }
        return InteractiveViewer(
          key: const ValueKey<String>('leaderboard-watermelon-viewer'),
          transformationController: _transform,
          constrained: false,
          minScale: 0.05,
          maxScale: 6,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: SizedBox(
            width: _pile.width,
            height: _pile.height,
            child: FushiEntranceScope(
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  for (final WatermelonBall ball in _pile.balls)
                    Positioned(
                      left: ball.center.x - ball.radius,
                      top: ball.center.y - ball.radius,
                      width: ball.radius * 2,
                      height: ball.radius * 2,
                      child: FushiStaggeredEntrance(
                        index: ball.index,
                        child: _WatermelonBallView(
                          row: widget.rows[ball.index],
                          radius: ball.radius,
                          isSelf:
                              widget.rows[ball.index].account.id ==
                              widget.selfId,
                          onTap: () =>
                              _openUser(widget.rows[ball.index].account.id),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 一颗球：头像 + 描边（自己用主色），够大的球在底部叠一枚字数胶囊。
class _WatermelonBallView extends StatelessWidget {
  const _WatermelonBallView({
    required this.row,
    required this.radius,
    required this.isSelf,
    required this.onTap,
  });

  final RankRow row;
  final double radius;
  final bool isSelf;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double ring = math.max(2, radius * 0.06);
    final bool showValue = radius >= 30;
    return FushiPressScale(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelf ? colors.primary : colors.surfaceContainerHighest,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.18),
                    blurRadius: radius * 0.18,
                    offset: Offset(0, radius * 0.06),
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(ring),
              child: LeaderboardAvatar(
                account: row.account,
                size: radius * 2 - ring * 2,
                onTap: onTap,
              ),
            ),
          ),
          if (showValue)
            Positioned(
              left: radius * 0.25,
              right: radius * 0.25,
              bottom: radius * 0.12,
              child: IgnorePointer(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: (isSelf ? colors.primary : colors.inverseSurface)
                          .withValues(alpha: 0.86),
                      borderRadius: const BorderRadius.all(
                        Radius.circular(999),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: Text(
                        NumberFormat.compact(
                          locale: Intl.getCurrentLocale(),
                        ).format(row.value),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              // 字号随球大小走，FittedBox 只负责缩小防溢出。
                              fontSize: math.max(10, radius * 0.24),
                              color: isSelf
                                  ? colors.onPrimary
                                  : colors.onInverseSurface,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
