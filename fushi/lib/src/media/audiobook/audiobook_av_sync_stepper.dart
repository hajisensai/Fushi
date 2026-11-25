import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 有声书音画同步（整本偏移 `delayMs`）步进器：普通阅读模式快捷设置
/// （`reader_quick_settings_sheet`）与歌词模式同步面板（`lyrics_av_sync_panel`）
/// 共用的**唯一实现**（反馈 G5xYgLcp4p：歌词模式里调同步要先离开歌词模式）。
///
/// 步进 / 读数 / 归零只在这里写一次：−1000 / −50 / 读数（点按归零）/ +50 / +1000，
/// 四颗步进键按住连续触发。按下时读 [delayMs] 的**当前值**再加减（按住连续时
/// 不依赖父级是否已重建），新值交给 [onChanged]——调用方一律接
/// `AudiobookPlayerController.setDelayMs`（夹取 + 立即重查高亮 + 写同一个偏好），
/// 所以点句跳转 / 单句试听 / 上下句（BUG-4243 修好的那条偏移路径）实时跟着变。
///
/// 这里只调**整本**偏移，不是逐行编辑——功能黑名单禁止逐行偏移。
class AudiobookAvSyncStepper extends StatelessWidget {
  const AudiobookAvSyncStepper({
    required this.delayMs,
    required this.onChanged,
    super.key,
  });

  /// 细调一步（毫秒）。
  static const int fineStepMs = 50;

  /// 粗调一步（毫秒）。
  static const int coarseStepMs = 1000;

  /// 步进器固有宽度：4 颗 48 号键 + 72 读数（快捷设置行据此声明 trailing 宽度）。
  static const double intrinsicWidth = 4 * kMinInteractiveDimension + 72;

  /// 读数 key（测试 / 焦点驱动用）。
  static const ValueKey<String> readoutKey = ValueKey<String>(
    'audiobook_av_sync_readout',
  );

  /// 步进键 key：`audiobook_av_sync_step_<±毫秒>`。
  static ValueKey<String> stepKey(int deltaMs) =>
      ValueKey<String>('audiobook_av_sync_step_$deltaMs');

  /// 读数文案：`0ms` / `+50ms` / `-950ms` / `+1.2s`。
  static String format(int ms) {
    final String sign = ms > 0 ? '+' : '';
    if (ms.abs() < 1000) return '$sign${ms}ms';
    return '$sign${(ms / 1000).toStringAsFixed(1)}s';
  }

  /// 当前偏移（通常就是 `AudiobookPlayerController.delayMs`）。
  final ValueListenable<int> delayMs;

  /// 新偏移（毫秒，未夹取——夹取由控制器负责）。
  final ValueChanged<int> onChanged;

  void _step(int deltaMs) => onChanged(delayMs.value + deltaMs);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    Widget step(int deltaMs, IconData icon) => AudiobookRepeatIconButton(
      key: stepKey(deltaMs),
      icon: icon,
      tooltip: '${deltaMs > 0 ? '+' : ''}${deltaMs}ms',
      onPressed: () => _step(deltaMs),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        step(-coarseStepMs, FushiIcons.doubleChevronLeft),
        step(-fineStepMs, FushiIcons.chevronLeft),
        ValueListenableBuilder<int>(
          valueListenable: delayMs,
          builder: (BuildContext context, int ms, Widget? _) {
            // 「点数字归零」：非零时读数用主色 + 下划线（可点的观感）并挂「归零」提示。
            return FushiTooltip(
              message: ms == 0 ? '' : t.av_sync_reset,
              child: FushiFocusable(
                onTap: ms == 0 ? null : () => onChanged(0),
                child: SizedBox(
                  width: 72,
                  height: kMinInteractiveDimension,
                  child: Center(
                    child: Text(
                      format(ms),
                      key: readoutKey,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                        color: ms == 0 ? null : theme.colorScheme.primary,
                        decoration: ms == 0
                            ? TextDecoration.none
                            : TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        step(fineStepMs, FushiIcons.chevronRight),
        step(coarseStepMs, FushiIcons.doubleChevronRight),
      ],
    );
  }
}

/// 按住连续触发的 48×48 图标键：单击触发一次；长按先触发一次，500ms 后每 100ms
/// 再触发一次，松手 / 手势被取消即停。
class AudiobookRepeatIconButton extends StatefulWidget {
  const AudiobookRepeatIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// 长按后开始连发前的等待。
  static const Duration initialDelay = Duration(milliseconds: 500);

  /// 连发间隔。
  static const Duration repeatInterval = Duration(milliseconds: 100);

  @override
  State<AudiobookRepeatIconButton> createState() =>
      _AudiobookRepeatIconButtonState();
}

class _AudiobookRepeatIconButtonState extends State<AudiobookRepeatIconButton> {
  Timer? _timer;

  void _start() {
    widget.onPressed();
    _timer = Timer(AudiobookRepeatIconButton.initialDelay, () {
      _timer = Timer.periodic(AudiobookRepeatIconButton.repeatInterval, (_) {
        widget.onPressed();
      });
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _stop(),
      // BUG-912 #3：手势被取消（指针滑出 / 识别器被上层夺走）而非正常 End 时，
      // onLongPressEnd 不必然回调；不补 cancel 的话 _timer 会持续每 100ms 连触
      // widget.onPressed()（数值狂涨 / 狂降）直到 dispose。与 video_fushi_page.dart
      // 的 _VideoRepeatGestureButton 对齐。
      onLongPressCancel: _stop,
      // 触屏长按归连发：官方按钮内的 Tooltip 默认 `longPress` 触发，它的
      // LongPressGestureRecognizer 比外层这个先进竞技场、同一时刻到期先接受，
      // 外层 onLongPressStart 永远等不到（按住只弹气泡、不连发）。这里改成
      // `manual`：触屏不再用长按抢手势，鼠标悬停气泡与无障碍名称照旧。
      child: TooltipTheme(
        data: TooltipTheme.of(
          context,
        ).copyWith(triggerMode: TooltipTriggerMode.manual),
        child: FushiIconButton(
          icon: widget.icon,
          size: 18,
          tooltip: widget.tooltip,
          constraints: const BoxConstraints.tightFor(
            width: kMinInteractiveDimension,
            height: kMinInteractiveDimension,
          ),
          padding: EdgeInsets.zero,
          onTap: widget.onPressed,
        ),
      ),
    );
  }
}
