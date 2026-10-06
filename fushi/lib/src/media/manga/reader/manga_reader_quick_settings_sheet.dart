/// 漫画阅读器的快捷设置面板（2026-10 重设计）：最常改的五项——阅读方向、单双页、
/// 图片缩放、底色、亮度——一屏放下，不必钻进四个页签的「全部设置」侧栏。
///
/// 外观全部来自共享组件：MD3 = 底部 sheet（顶部拖柄、28 大圆角）+ M3 Expressive
/// 连接式按钮组（[FushiSegmentedButton]）+ Expressive 滑块；Apple = iOS 26 悬浮
/// 玻璃 sheet / macOS 顶部垂下的 sheet + 液态玻璃分段控件（均由
/// [adaptiveModalSheet] 与 [FushiSegmentedButton] 按设计系统分派）。行按
/// [FushiStaggeredEntrance] 错峰进场。
///
/// 写入与「全部设置」同一份本书覆盖（由页面的 [onPatch] 落库 + 重应用）；本面板
/// 只维护「界面立即显示新值、落库串行」的乐观状态，落库失败回滚到上一份成功值。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 阅读方向分段的取值：两种翻页方向 + 竖向长条（条漫）。
enum MangaQuickDirection { rtl, ltr, vertical }

/// 当前布局 → 方向分段的选中值（纯函数）：连续 / 纵向分页都算「竖向」。
MangaQuickDirection mangaQuickDirectionOf({
  required MangaReadingMode mode,
  required String direction,
}) {
  if (mode.isContinuous) return MangaQuickDirection.vertical;
  return direction == 'ltr' ? MangaQuickDirection.ltr : MangaQuickDirection.rtl;
}

/// 方向分段选中 [next] 时要写入的覆盖补丁（纯函数）。
///
///  * 竖向 → 关掉自动判定、布局写成条漫；
///  * 左右方向 → 只写方向；当前是竖向布局时顺带切回翻页（否则选了「从右到左」
///    页面却仍是长条，选择看起来没生效）。
Map<String, Object?> mangaQuickDirectionPatch({
  required MangaQuickDirection next,
  required MangaReadingMode currentMode,
}) {
  switch (next) {
    case MangaQuickDirection.vertical:
      return <String, Object?>{
        'autoMode': false,
        'mode': MangaReadingMode.webtoon.storageKey,
      };
    case MangaQuickDirection.rtl:
    case MangaQuickDirection.ltr:
      final String direction = next == MangaQuickDirection.ltr ? 'ltr' : 'rtl';
      if (!currentMode.isContinuous) {
        return <String, Object?>{'direction': direction};
      }
      return <String, Object?>{
        'direction': direction,
        'autoMode': false,
        'mode': MangaReadingMode.spread.storageKey,
      };
  }
}

/// 打开快捷设置。返回 true = 用户点了「全部设置」（页面随后打开完整侧栏）。
Future<bool?> showMangaReaderQuickSettingsSheet({
  required BuildContext context,
  required MangaReaderPreferences preferences,
  required MangaReadingMode currentMode,
  required MangaSpreadPreference spreadPreference,
  required ValueChanged<MangaSpreadPreference> onSpreadPreferenceChanged,
  required Future<void> Function(Map<String, Object?> patch) onPatch,
}) {
  return adaptiveModalSheet<bool>(
    context: context,
    builder: (BuildContext context) => MangaReaderQuickSettingsSheet(
      preferences: preferences,
      currentMode: currentMode,
      spreadPreference: spreadPreference,
      onSpreadPreferenceChanged: onSpreadPreferenceChanged,
      onPatch: onPatch,
    ),
  );
}

class MangaReaderQuickSettingsSheet extends StatefulWidget {
  const MangaReaderQuickSettingsSheet({
    super.key,
    required this.preferences,
    required this.currentMode,
    required this.spreadPreference,
    required this.onSpreadPreferenceChanged,
    required this.onPatch,
  });

  /// 打开时本书生效的偏好（全局默认 + 本书覆盖）。
  final MangaReaderPreferences preferences;

  /// 打开时页面实际在用的布局（自动判定时与偏好里的 mode 可能不同）。
  final MangaReadingMode currentMode;
  final MangaSpreadPreference spreadPreference;
  final ValueChanged<MangaSpreadPreference> onSpreadPreferenceChanged;
  final Future<void> Function(Map<String, Object?> patch) onPatch;

  @override
  State<MangaReaderQuickSettingsSheet> createState() =>
      _MangaReaderQuickSettingsSheetState();
}

class _MangaReaderQuickSettingsSheetState
    extends State<MangaReaderQuickSettingsSheet> {
  late MangaReaderPreferences _prefs = widget.preferences;
  late MangaReaderPreferences _persisted = widget.preferences;
  late MangaReadingMode _mode = widget.currentMode;
  late MangaReadingMode _persistedMode = widget.currentMode;
  late MangaSpreadPreference _spread = widget.spreadPreference;

  /// 拖动中的亮度（松手才落库）。
  int? _brightnessDrag;

  /// 落库串行：前一笔没写完时后一笔排在后面，绝不并发读改写同一份覆盖。
  Future<void> _chain = Future<void>.value();

  void _apply(Map<String, Object?> patch, {MangaReadingMode? mode}) {
    setState(() {
      _prefs = _prefs.copyWithJson(patch);
      if (mode != null) _mode = mode;
    });
    _chain = _chain.then((_) async {
      try {
        await widget.onPatch(patch);
        _persisted = _persisted.copyWithJson(patch);
        if (mode != null) _persistedMode = mode;
      } on Object {
        if (!mounted) return;
        setState(() {
          _prefs = _persisted;
          _mode = _persistedMode;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> json = _prefs.toJson();
    final MangaQuickDirection direction = mangaQuickDirectionOf(
      mode: _mode,
      direction: _prefs.direction,
    );
    final String scale = '${json['scaleType'] ?? 'fit_screen'}';
    final String background = _prefs.background;
    final int brightness = (_brightnessDrag ?? _prefs.brightness).clamp(
      -100,
      100,
    );
    final List<Widget> rows = <Widget>[
      _QuickRow(
        title: t.manga_reading_direction,
        child: FushiSegmentedButton<MangaQuickDirection>(
          key: const ValueKey<String>('manga_quick_direction'),
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: <ButtonSegment<MangaQuickDirection>>[
            ButtonSegment<MangaQuickDirection>(
              value: MangaQuickDirection.rtl,
              label: Text(t.manga_direction_rtl),
            ),
            ButtonSegment<MangaQuickDirection>(
              value: MangaQuickDirection.ltr,
              label: Text(t.manga_direction_ltr),
            ),
            ButtonSegment<MangaQuickDirection>(
              value: MangaQuickDirection.vertical,
              label: Text(t.manga_reading_mode_webtoon),
            ),
          ],
          selected: <MangaQuickDirection>{direction},
          onSelectionChanged: (Set<MangaQuickDirection> next) {
            final MangaQuickDirection value = next.single;
            if (value == direction) return;
            final Map<String, Object?> patch = mangaQuickDirectionPatch(
              next: value,
              currentMode: _mode,
            );
            _apply(
              patch,
              mode: value == MangaQuickDirection.vertical
                  ? MangaReadingMode.webtoon
                  : (_mode.isContinuous ? MangaReadingMode.spread : null),
            );
          },
        ),
      ),
      _QuickRow(
        title: t.spread_mode,
        child: FushiSegmentedButton<MangaSpreadPreference>(
          key: const ValueKey<String>('manga_quick_spread'),
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: <ButtonSegment<MangaSpreadPreference>>[
            ButtonSegment<MangaSpreadPreference>(
              value: MangaSpreadPreference.auto,
              label: Text(t.spread_auto),
            ),
            ButtonSegment<MangaSpreadPreference>(
              value: MangaSpreadPreference.single,
              label: Text(t.spread_off),
            ),
            ButtonSegment<MangaSpreadPreference>(
              value: MangaSpreadPreference.double,
              label: Text(t.spread_on),
            ),
          ],
          selected: <MangaSpreadPreference>{_spread},
          // 单双页只对翻页布局有意义；条漫恒单列。
          onSelectionChanged: _mode == MangaReadingMode.spread
              ? (Set<MangaSpreadPreference> next) {
                  setState(() => _spread = next.single);
                  widget.onSpreadPreferenceChanged(next.single);
                }
              : null,
        ),
      ),
      _QuickRow(
        title: t.manga_reader_scale,
        child: FushiSegmentedButton<String>(
          key: const ValueKey<String>('manga_quick_scale'),
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          // 拉伸 / 智能适应不在快捷档里：选中它们时这里一档都不亮，去「全部设置」改。
          emptySelectionAllowed: true,
          segments: <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: MangaScaleType.fitScreen.key,
              label: Text(t.manga_scale_fit_screen),
            ),
            ButtonSegment<String>(
              value: MangaScaleType.fitWidth.key,
              label: Text(t.manga_scale_fit_width),
            ),
            ButtonSegment<String>(
              value: MangaScaleType.fitHeight.key,
              label: Text(t.manga_scale_fit_height),
            ),
            ButtonSegment<String>(
              value: MangaScaleType.original.key,
              label: Text(t.manga_scale_original),
            ),
          ],
          selected: <String>{
            if (const <String>{
              'fit_screen',
              'fit_width',
              'fit_height',
              'original',
            }.contains(scale))
              scale,
          },
          onSelectionChanged: (Set<String> next) {
            if (next.isEmpty || next.single == scale) return;
            _apply(<String, Object?>{'scaleType': next.single});
          },
        ),
      ),
      _QuickRow(
        title: t.manga_background,
        child: FushiSegmentedButton<String>(
          key: const ValueKey<String>('manga_quick_background'),
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: <ButtonSegment<String>>[
            for (final (String value, String label) in <(String, String)>[
              ('black', t.manga_background_black),
              ('gray', t.manga_background_gray),
              ('white', t.manga_background_white),
              ('theme', t.manga_background_theme),
            ])
              ButtonSegment<String>(value: value, label: Text(label)),
          ],
          selected: <String>{background},
          onSelectionChanged: (Set<String> next) {
            if (next.single == background) return;
            _apply(<String, Object?>{'background': next.single});
          },
        ),
      ),
      AdaptiveSettingsSliderRow(
        key: const ValueKey<String>('manga_quick_brightness'),
        title: t.manga_reader_brightness,
        icon: Icons.brightness_6_outlined,
        value: brightness.toDouble(),
        min: -100,
        max: 100,
        divisions: 200,
        label: '$brightness',
        readout: '$brightness',
        onChanged: (double v) => setState(() => _brightnessDrag = v.round()),
        onChangeEnd: (double v) {
          setState(() => _brightnessDrag = null);
          if (v.round() == _prefs.brightness) return;
          _apply(<String, Object?>{'brightness': v.round()});
        },
      ),
      AdaptiveSettingsNavigationRow(
        key: const ValueKey<String>('manga_quick_all_settings'),
        title: t.manga_reader_all_settings,
        icon: Icons.settings_outlined,
        showIcon: true,
        onTap: () => Navigator.of(context).pop(true),
      ),
    ];
    return FushiModalSheetFrame(
      title: t.manga_reader_quick_settings,
      maxHeightFactor: 0.9,
      scrollable: true,
      bodyPadding: const EdgeInsets.only(bottom: 12),
      body: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows.length; i++)
              FushiStaggeredEntrance(
                index: i,
                // 共享设置行自带 16 的左右内边距，再补 8 与分段行的 24 对齐。
                child: rows[i] is _QuickRow
                    ? rows[i]
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: rows[i],
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一行「小标题 + 整行宽的分段控件」：分段在窄 sheet 里与标题并排时只分到一百来
/// 像素，选项文字会被截掉，所以控件放到标题下方占满整行。
class _QuickRow extends StatelessWidget {
  const _QuickRow({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final Color label = apple
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: label,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
