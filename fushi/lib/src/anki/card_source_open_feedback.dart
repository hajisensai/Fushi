import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';

/// 一段「打开卡片来源」途中的等待结果：[cancelled] 为 true 表示用户在等待时点了取消
/// （调用方放弃这次跳转、不提示「没有来源」）；否则 [value] 是 [work] 的结果。
typedef CardSourceAwaited<T> = ({T? value, bool cancelled});

/// 反馈 7gkdbfCXQ0：点卡片来源后要先去互联 host 拉清单（含候选地址选路）才能跳，
/// 这段网络等待原本界面上什么都没有，用户以为点坏了。等 [work] 期间在 [navigator]
/// 上**立刻**挂一个不定态进度对话框（遮罩挡住重复点击），带取消键（系统返回键
/// 同）；[work] 完成或取消后关掉对话框并等它出栈，调用方再推目标页，免得目标页被
/// 压在正在退场的对话框下面。
///
/// 取消只放弃这次跳转：[work] 照常跑完（清单照样进缓存，下次点就是秒开），它迟到的
/// 结果 / 错误被丢弃。[work] 在取消前失败则原样抛给调用方。
Future<CardSourceAwaited<T>> awaitWithCardSourceOpeningFeedback<T>({
  required NavigatorState navigator,
  required Future<T> work,
}) async {
  final Completer<void> cancel = Completer<void>();
  final FushiProgressDialogHandle dialog = showFushiProgressDialog(
    context: navigator.context,
    title: t.card_source_remote_loading_title,
    message: t.card_source_remote_loading_hint,
    onCancel: () {
      if (!cancel.isCompleted) cancel.complete();
    },
  );
  try {
    final T? value = await Future.any<T?>(<Future<T?>>[
      work,
      cancel.future.then<T?>((void _) => null),
    ]);
    if (cancel.isCompleted) return (value: null, cancelled: true);
    return (value: value, cancelled: false);
  } finally {
    dialog.close();
    await dialog.done;
  }
}
