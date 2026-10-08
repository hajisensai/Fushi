import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';

/// 用户偏好的视频制卡图片模式 → 对**本次制卡的目标笔记类型**实际生效的模式。
///
/// 只有 [VideoMiningImageMode.videoClip] 依赖模板：同步片段卡没有 `<img>` 封面，也没有
/// 独立的句子音频，只在模板原样渲染图片字段时可用（判据见
/// [noteTypeRendersSynchronizedClip]）。模板确定不支持（Kiku 这类二次解析字段的模板）
/// 时改走 [VideoMiningImageMode.gif]：动图封面 + 独立句子音频，任何模板都认。读不到模板
/// （后端不支持读取、没选笔记类型、读取失败）时保持偏好不变——无法证明不支持，不改
/// 既有行为。
///
/// 必须在**产出媒体之前**求值：录制片段的来源（Netflix 扩展、galgame 窗口录制）是按模式
/// 决定录片段还是录动图的，事后无法把片段改回动图。
Future<VideoMiningImageMode> resolveTargetMiningImageMode(
  VideoMiningImageMode preferred, {
  required BaseAnkiRepository repo,
}) async {
  if (!preferred.isVideoClip) return preferred;
  final bool? supported = await probeSynchronizedClipSupport(repo);
  if (supported != false) return preferred;
  engineLog.logDiagnostic(
    'Anki.synchronizedVideo.templateUnsupported',
    'note type does not render the card image field directly; using gif',
  );
  await _notifyTemplateFallback(repo);
  return VideoMiningImageMode.gif;
}

/// [resolveTargetMiningImageMode] 因目标笔记类型不渲染同步片段而改走 gif 时的通知点，
/// 参数是笔记类型名。app 在 `main()` 装配（每个笔记类型提示一次、引导去一键适配）；
/// 不装 = 静默降级。
void Function(String noteTypeName)? onSynchronizedClipTemplateFallback;

/// 制卡与设置页「未适配」提示共用的判据。null = 无法判定（见
/// [resolveTargetMiningImageMode]）。只吞后端异常（Anki 没开、主机不可达）：这种情况下
/// 制卡还可能被待补发队列接住，探测不能替它判死刑；编程错误照抛。
Future<bool?> probeSynchronizedClipSupport(BaseAnkiRepository repo) async {
  try {
    return await repo.rendersSynchronizedClip();
  } on Exception catch (error) {
    engineLog.logDiagnostic('Anki.synchronizedVideo.templateProbe', error);
    return null;
  }
}

Future<void> _notifyTemplateFallback(BaseAnkiRepository repo) async {
  final void Function(String noteTypeName)? notify =
      onSynchronizedClipTemplateFallback;
  if (notify == null) return;
  final String? noteTypeName;
  try {
    final AnkiSettings settings = await repo.loadSettings();
    noteTypeName =
        settings.selectedNoteType?.name ?? settings.selectedNoteTypeName;
  } on Exception catch (error) {
    engineLog.logDiagnostic('Anki.synchronizedVideo.templateNotice', error);
    return;
  }
  if (noteTypeName != null) notify(noteTypeName);
}
