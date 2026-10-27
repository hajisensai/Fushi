/// AI 对话输入栏的「附上屏幕文字」（spec `2026-10-26-ai-operations-agent-design.md`
/// §6.4）：点一下 → 先把 AI 面板藏掉 → 截当前窗口 → 系统 OCR 取全文 → 作为上下文
/// 附进**下一句**（`AgentUiContext.extra['screenText']`），输入栏上方出一颗可删的
/// chip，发送后自动清掉。chip 点开能手改识别出的文字（OCR 认错的字发送前改掉）。
///
/// 模型能收图（提供商勾了「支持图片输入」）时连截图一起附：截图另起一颗带缩略图
/// 的 chip，可单独删掉；发送时作为这句的图片交给模型，文字照常进上下文。
///
/// 截图与识别走 [captureScreenText]（与反馈截图、悬浮球截屏识字同一套底层能力）。
/// 平台没有系统 OCR（[screenTextCaptureSupported] 为 false）时只有能收图的模型
/// 才出按钮——那时只附截图。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatImage;
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
const ValueKey<String> kAiAgentScreenImageChipKey = ValueKey<String>(
  'ai-agent-screen-image-chip',
);

/// 发送时取走的附件：屏幕文字（进上下文）与截图（作为这句的图片）。
typedef AiAgentScreenAttachments = ({String? text, Uint8List? image});

/// 截图 → 发给模型的图片；没附图时为空表。
List<AiChatImage> aiAgentImagesFor(Uint8List? image) => image == null
    ? const <AiChatImage>[]
    : <AiChatImage>[AiChatImage(bytes: image)];

/// 取屏幕的函数形（[captureScreenText] 的子集；测试注入假实现）。
typedef AiAgentScreenCapture =
    Future<ScreenTextCaptureResult> Function({bool keepImage, bool recognize});

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

/// 一场对话里「附上屏幕」的状态：截取中 / 已附上的文字与截图。
class AiAgentScreenTextAttachment extends ChangeNotifier {
  AiAgentScreenTextAttachment({AiAgentScreenCapture? capture})
    : _capture = capture ?? captureScreenText;

  final AiAgentScreenCapture _capture;

  String? _text;
  Uint8List? _image;
  bool _busy = false;
  bool _disposed = false;

  /// 已附上、等下一句带走的屏幕文字；null = 没附。
  String? get text => _text;

  /// 已附上的截图（PNG）；null = 没附。
  Uint8List? get image => _image;

  /// 正在截屏 / 识别。
  bool get busy => _busy;

  /// 取走并清掉（发送时调用：附件只跟下一句走）。
  AiAgentScreenAttachments take() {
    final AiAgentScreenAttachments value = (text: _text, image: _image);
    if (_text == null && _image == null) return value;
    _text = null;
    _image = null;
    _notify();
    return value;
  }

  /// 用户点掉了文字 chip。
  void clear() {
    if (_text == null) return;
    _text = null;
    _notify();
  }

  /// 用户点掉了截图 chip。
  void clearImage() {
    if (_image == null) return;
    _image = null;
    _notify();
  }

  /// 用户手改了识别出的文字；改成空白 = 不附文字。超长截到
  /// [kScreenTextMaxChars]（与识别结果同一上限）。
  void editText(String value) {
    final String trimmed = value.trim();
    final String? next = trimmed.isEmpty
        ? null
        : trimmed.length <= kScreenTextMaxChars
        ? trimmed
        : trimmed.substring(0, kScreenTextMaxChars);
    if (next == _text) return;
    _text = next;
    _notify();
  }

  /// 截屏（[keepImage] 时连图留下）并识字。[context] 所在的弹层路由（AI 半屏
  /// 面板 / 侧栏）在截图期间整层 offstage（连同遮罩），截完恢复——免得截到 AI
  /// 面板自己。整页外壳不藏（藏了下面也是不透明路由盖着，截不到别的），故整页
  /// 外壳不提供本按钮。
  Future<void> attach(BuildContext context, {bool keepImage = false}) async {
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
      result = await _capture(
        keepImage: keepImage,
        recognize: screenTextCaptureSupported,
      );
    } on Object {
      result = const ScreenTextCaptureResult(ScreenTextCaptureStatus.failed);
    } finally {
      if (hide && route.isActive) route.offstage = false;
    }
    _busy = false;
    if (result.status == ScreenTextCaptureStatus.ok) _text = result.text;
    final Uint8List? image = keepImage ? result.image : null;
    if (image != null) _image = image;
    _notify();
    // 截图附上了，文字没认出来也不报错：图本身就是模型要看的东西。
    if (image != null) return;
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

/// 输入栏里的「附上屏幕」按钮：截取中换成转圈（交叉淡变，时长走
/// [fushiMotionDuration]，墨水屏 / 减弱动效归零）。[keepImage] = 模型能收图，
/// 连截图一起附（tooltip 随之说明）。
class AiAgentScreenTextButton extends StatelessWidget {
  const AiAgentScreenTextButton({
    required this.attachment,
    this.enabled = true,
    this.keepImage = false,
    super.key,
  });

  final AiAgentScreenTextAttachment attachment;
  final bool enabled;
  final bool keepImage;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: attachment,
      builder: (BuildContext context, Widget? _) {
        final bool busy = attachment.busy;
        final bool attached =
            attachment.text != null || attachment.image != null;
        return FushiIconButtonControl(
          key: kAiAgentAttachScreenTextKey,
          tooltip: keepImage
              ? t.ai_agent_attach_screen_image
              : t.ai_agent_attach_screen_text,
          onPressed: !enabled || busy
              ? null
              : () =>
                    unawaited(attachment.attach(context, keepImage: keepImage)),
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
                    attached
                        ? FushiIcons.filled(FushiIcons.ocr)
                        : FushiIcons.ocr,
                    key: const ValueKey<String>('icon'),
                  ),
          ),
        );
      },
    );
  }
}

/// 输入栏上方的附件 chip：「屏幕截图」（缩略图）与「屏幕文字（N 字）」各一颗，
/// 附上时淡入 + 展开，删掉 / 发送后淡出 + 收起（[fushiMotionDuration] +
/// [FushiMotion] 曲线）。点文字 chip 打开编辑框手改识别结果。
class AiAgentScreenTextChip extends StatelessWidget {
  const AiAgentScreenTextChip({required this.attachment, super.key});

  final AiAgentScreenTextAttachment attachment;

  Future<void> _edit(BuildContext context, String text) async {
    final String? edited = await showFushiTextInputDialog(
      context: context,
      title: t.ai_agent_screen_text_edit_title,
      message: t.ai_agent_screen_text_edit_hint,
      initialValue: text,
      icon: FushiIcons.edit,
      allowEmpty: true,
      maxLines: 12,
      keyboardType: TextInputType.multiline,
    );
    if (edited != null) attachment.editText(edited);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: attachment,
      builder: (BuildContext context, Widget? _) {
        final String? text = attachment.text;
        final Uint8List? image = attachment.image;
        final List<Widget> chips = <Widget>[
          if (image != null)
            FushiInputChip(
              key: kAiAgentScreenImageChipKey,
              avatar: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  image,
                  width: 24,
                  height: 18,
                  fit: BoxFit.cover,
                  cacheWidth: 96,
                  gaplessPlayback: true,
                ),
              ),
              label: Text(t.ai_agent_screen_image_chip),
              onDeleted: attachment.clearImage,
            ),
          if (text != null)
            FushiInputChip(
              key: kAiAgentScreenTextChipKey,
              avatar: const FushiIcon(FushiIcons.ocr, size: 16),
              label: Text(t.ai_agent_screen_text_chip(n: '${text.length}')),
              tooltip: t.ai_agent_screen_text_edit_title,
              onPressed: () => unawaited(_edit(context, text)),
              onDeleted: attachment.clear,
            ),
        ];
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
          child: chips.isEmpty
              ? const SizedBox(key: ValueKey<String>('none'), width: 0)
              : Padding(
                  key: ValueKey<String>(
                    'chips-${image != null}-${text != null}',
                  ),
                  padding: const EdgeInsets.only(bottom: 6, left: 4),
                  child: Wrap(spacing: 6, runSpacing: 6, children: chips),
                ),
        );
      },
    );
  }
}
