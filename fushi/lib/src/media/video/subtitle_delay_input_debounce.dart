import 'dart:async';

import 'package:flutter/widgets.dart';

/// 字幕延迟数值输入框「边键入边生效」的共享去抖（BUG-918）。
///
/// 两处字幕调轴数值输入框（`VideoSubtitleSyncRow` 与
/// `subtitle_waveform_align_panel.dart` 的放大对轴视图）此前各持一份逐行相同的
/// 去抖逻辑（原字段只在 onSubmitted（Enter）提交、无 onChanged，用户报「不按回车
/// 不更新、backspace 没反应」），命名统一轮抽成本 helper 两处共用：
///
/// - [onChanged]：解析成功就去抖 [delay]（默认 350ms）后 `commit(值,
///   syncField:false)` 实时生效，无需回车；不回写输入框文本，保住光标与退格。
///   空 / 只有正负号等未成形输入解析失败 → 不提交、不回退（保留用户正在敲的
///   中间态）。
/// - [onSubmitted]：取消挂起去抖后立即提交；非法输入回退当前权威值文本、不改延迟。
/// - [cancelPending]：权威提交路径（滑条 / ± 按钮 / 回车回写文本）先调它，免得一个
///   陈旧的键入值在按钮点击后姗姗迟到覆盖掉刚设的值（BUG-918）。
/// - [dispose]：宿主 State.dispose 时取消挂起 Timer。
class SubtitleDelayInputDebounce {
  SubtitleDelayInputDebounce({
    required TextEditingController controller,
    required bool Function() isMounted,
    required int Function() currentDelayMs,
    required void Function(int delayMs, {bool syncField}) commit,
    this.delay = const Duration(milliseconds: 350),
  })  : _controller = controller,
        _isMounted = isMounted,
        _currentDelayMs = currentDelayMs,
        _commit = commit;

  /// 数值输入框的控制器（onSubmitted 非法输入时回退文本用）。
  final TextEditingController _controller;

  /// 宿主 State 的 `mounted`（去抖回调触发时宿主可能已 dispose）。
  final bool Function() _isMounted;

  /// 当前权威延迟值（毫秒），onSubmitted 非法输入时回退输入框文本用。
  final int Function() _currentDelayMs;

  /// 权威提交（宿主 `_commitDelay` / `_commit` 的 tear-off）。`syncField:false`
  /// 表示键入过程中的提交：不回写输入框文本，避免光标弹到行尾、退格错位。
  final void Function(int delayMs, {bool syncField}) _commit;

  /// 键入停手到提交的去抖间隔。
  final Duration delay;

  Timer? _timer;

  /// 数值输入框 onChanged：解析成功就去抖 [delay] 后实时提交（BUG-918），无需回车。
  void onChanged(String raw) {
    _timer?.cancel();
    final int? parsed = int.tryParse(raw.trim());
    if (parsed == null) return;
    _timer = Timer(delay, () {
      if (!_isMounted()) return;
      // syncField:false —— 键入过程中不回写输入框文本，避免光标弹到行尾、退格错位。
      _commit(parsed, syncField: false);
    });
  }

  /// 数值输入框 onSubmitted（Enter）：取消挂起去抖后立即提交；非法输入 → 回退到
  /// 当前权威值文本，不改延迟。
  void onSubmitted(String raw) {
    _timer?.cancel();
    final int? parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      _controller.text = '${_currentDelayMs()}';
      return;
    }
    _commit(parsed, syncField: true);
  }

  /// 取消挂起的键入去抖。权威提交路径（滑条 / ± 按钮 / 回车回写文本）必须先调它，
  /// 免得陈旧键入值迟到覆盖刚设的值（BUG-918）。
  void cancelPending() => _timer?.cancel();

  /// 宿主 State.dispose 时调用，取消挂起 Timer。
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
