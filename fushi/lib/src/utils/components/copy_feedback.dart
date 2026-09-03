import 'dart:async';

import 'package:flutter/widgets.dart';

/// 复制按钮「✓ 已复制」瞬态维持的时长。
const Duration kCopyFeedbackDuration = Duration(milliseconds: 1500);

/// 复制按钮点击后的就地反馈状态：调用 [markCopied] 后 `copied` 变 true，
/// [kCopyFeedbackDuration] 后自动回落 false；期间再点则重新计时。
///
/// 为什么不只靠 toast / OSD：视频页 OSD 画在视频区左上角，用户眼睛盯着的是字幕列表
/// 行尾或查词弹窗顶栏那颗按钮，反馈落在视线之外等于没有反馈。按钮本身图标切成 ✓、
/// tooltip 切成「已复制」才是用户看得见的互动。状态归按钮自己持有，调用方只在
/// 真的写了剪贴板时调 [markCopied]（空文本不装成功）。
class CopyFeedback extends StatefulWidget {
  const CopyFeedback({
    required this.builder,
    this.duration = kCopyFeedbackDuration,
    super.key,
  });

  /// 按 `copied` 渲染按钮；`markCopied` 由点击处理器在复制成功后调用。
  final Widget Function(
    BuildContext context,
    bool copied,
    VoidCallback markCopied,
  ) builder;

  /// ✓ 状态维持时长。
  final Duration duration;

  @override
  State<CopyFeedback> createState() => _CopyFeedbackState();
}

class _CopyFeedbackState extends State<CopyFeedback> {
  bool _copied = false;
  Timer? _resetTimer;

  void _markCopied() {
    _resetTimer?.cancel();
    // 回落只有一道门：定时器随 [dispose] 取消，故到点时 State 必然还活着。
    // 再加一层 `if (!mounted) return` 是与那道门互为冗余的第二道——两道都在时，
    // 删掉任意一道测试都照样绿（谁都钉不住），砍到只剩一道反而让 dispose 里的
    // cancel 变成可被变异测试杀掉的真断言。
    _resetTimer = Timer(
      widget.duration,
      () => setState(() => _copied = false),
    );
    if (!_copied) setState(() => _copied = true);
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _copied, _markCopied);
  }
}
