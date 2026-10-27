/// AI 对话输入栏的「附上屏幕文字」（spec `2026-10-26-ai-operations-agent-design.md`
/// §6.4）：点一下 → 先把 AI 面板藏掉 → 截当前窗口 → 系统 OCR 取全文 → 作为上下文
/// 附进**下一句**（`AgentUiContext.extra['screenText']`），输入栏上方出一颗可删的
/// chip，发送后自动清掉。
///
/// 截图与识别走 [captureScreenText]（与反馈截图、悬浮球截屏识字同一套底层能力），
/// 平台没有系统 OCR 时（[screenTextCaptureSupported] 为 false）按钮不出。
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/floating_ball/app_floating_ball_host.dart'
    show pendingSystemOcrSetup;
import 'package:fushi/src/ocr/screen_text_capture.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart'
    show kSystemOcrModelUnavailableReason;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 附进上下文时用的键（模型在 `screenText` 下读到屏幕全文）。
const String kAiAgentScreenTextKey = 'screenText';

/// 「附上屏幕文字」按钮 / chip 的 key（测试 / 焦点驱动定位用）。
const ValueKey<String> kAiAgentAttachScreenTextKey = ValueKey<String>(
  'ai-agent-attach-screen-text',
);
const ValueKey<String> kAiAgentScreenTextChipKey = ValueKey<String>(
  'ai-agent-screen-text-chip',
);

/// 把屏幕文字并进本句的上下文：[base] 为空（没有页面上下文 / 用户点掉了上下文
/// chip）时新起一份 `general` 上下文。[screenText] 为空时原样返回 [base]。
AgentUiContext? aiAgentContextWithScreenText(
  AgentUiContext? base,
  String? screenText,
) {
  if (screenText == null || screenText.isEmpty) return base;
  return AgentUiContext(
    scene: base?.scene ?? 'general',
    page: base?.page,
    itemKind: base?.itemKind,
    itemId: base?.itemId,
    itemTitle: base?.itemTitle,
    position: base?.position,
    extra: <String, Object?>{
      ...?base?.extra,
      kAiAgentScreenTextKey: screenText,
    },
  );
}

/// 一场对话里「附上屏幕文字」的状态：截取中 / 已附上的文字。
class AiAgentScreenTextAttachment extends ChangeNotifier {
  AiAgentScreenTextAttachment({ScreenTextCapture? capture})
    : _capture = capture ?? captureScreenText;

  final ScreenTextCapture _capture;

  String? _text;
  bool _busy = false;
  bool _disposed = false;

  /// 已附上、等下一句带走的屏幕文字；null = 没附。
  String? get text => _text;

  /// 正在截屏 / 识别。
  bool get busy => _busy;

  /// 取走并清掉（发送时调用：屏幕文字只附进下一句）。
  String? take() {
    final String? value = _text;
    if (value == null) return null;
    _text = null;
    _notify();
    return value;
  }

  /// 用户点掉了 chip。
  void clear() {
    if (_text == null) return;
    _text = null;
    _notify();
  }

  /// 截屏识字。[context] 所在的弹层路由（AI 半屏面板 / 侧栏）在截图期间整层
  /// offstage（连同遮罩），截完恢复——免得截到 AI 面板自己。整页外壳不藏（藏了
  /// 下面也是不透明路由盖着，截不到别的），故整页外壳不提供本按钮。
  Future<void> attach(BuildContext context) async {
    if (_busy) return;
    _busy = true;
    _notify();
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    final bool hide = route is PopupRoute<Object?>;
    ScreenTextCaptureResult result;
    try {
      if (hide) {
        route.offstage = true;
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
      }
      result = await _capture();
    } on Object {
      result = const ScreenTextCaptureResult(ScreenTextCaptureStatus.failed);
    } finally {
      if (hide && route.isActive) route.offstage = false;
    }
    _busy = false;
    if (result.status == ScreenTextCaptureStatus.ok) _text = result.text;
    _notify();
    switch (result.status) {
      case ScreenTextCaptureStatus.ok:
        break;
      case ScreenTextCaptureStatus.empty:
        FushiToast.show(msg: t.ai_agent_screen_text_empty);
      case ScreenTextCaptureStatus.unavailable:
        if (result.reason == kSystemOcrModelUnavailableReason) {
          // Android ML Kit 模型没就绪：与悬浮球截屏识字同一出口，直接带用户去
          // 配模型（BUG-2906），不只丢一句「不可用」。
          pendingSystemOcrSetup.value = true;
        } else {
          FushiToast.show(msg: t.ai_agent_screen_text_unavailable);
        }
      case ScreenTextCaptureStatus.failed:
        FushiToast.show(msg: t.ai_agent_screen_text_failed);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 输入栏里的「附上屏幕文字」按钮：截取中换成转圈（交叉淡变，时长走
/// [fushiMotionDuration]，墨水屏 / 减弱动效归零）。
class AiAgentScreenTextButton extends StatelessWidget {
  const AiAgentScreenTextButton({
    required this.attachment,
    this.enabled = true,
    super.key,
  });

  final AiAgentScreenTextAttachment attachment;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: attachment,
      builder: (BuildContext context, Widget? _) {
        final bool busy = attachment.busy;
        return FushiIconButtonControl(
          key: kAiAgentAttachScreenTextKey,
          tooltip: t.ai_agent_attach_screen_text,
          onPressed: !enabled || busy
              ? null
              : () => unawaited(attachment.attach(context)),
          icon: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: busy
                ? const SizedBox.square(
                    key: ValueKey<String>('busy'),
                    dimension: 20,
                    child: FushiCircularProgressIndicator.adaptive(),
                  )
                : FushiIcon(
                    attachment.text == null
                        ? FushiIcons.ocr
                        : FushiIcons.filled(FushiIcons.ocr),
                    key: const ValueKey<String>('icon'),
                  ),
          ),
        );
      },
    );
  }
}

/// 输入栏上方「屏幕文字（N 字）」chip：附上时淡入 + 展开，删掉 / 发送后淡出 +
/// 收起（[fushiMotionDuration] + [FushiMotion] 曲线）。
class AiAgentScreenTextChip extends StatelessWidget {
  const AiAgentScreenTextChip({required this.attachment, super.key});

  final AiAgentScreenTextAttachment attachment;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: attachment,
      builder: (BuildContext context, Widget? _) {
        final String? text = attachment.text;
        return AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axisAlignment: -1,
                  child: child,
                ),
              ),
          child: text == null
              ? const SizedBox(key: ValueKey<String>('none'), width: 0)
              : Padding(
                  key: const ValueKey<String>('chip'),
                  padding: const EdgeInsets.only(bottom: 6, left: 4),
                  child: FushiInputChip(
                    key: kAiAgentScreenTextChipKey,
                    avatar: const FushiIcon(FushiIcons.ocr, size: 16),
                    label: Text(
                      t.ai_agent_screen_text_chip(n: '${text.length}'),
                    ),
                    onDeleted: attachment.clear,
                  ),
                ),
        );
      },
    );
  }
}
