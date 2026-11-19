/// 本地 TTS 引擎（GPT-SoVITS / Irodori / VOICEVOX / Irodori 声线包）共用的日志窗。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 弹一个定高 360 的等宽日志窗，`reverse` 贴底滚（新行在最下面，打开即看到最近的
/// 输出）。这是有意的内层定高滚动区，不是「装不下兜底」，所以不交给
/// FushiAlertDialog 的内容区滚动。
Future<void> showTtsLocalLogDialog(
  BuildContext context, {
  required String title,
  required List<String> lines,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 560,
      height: 360,
      child: SingleChildScrollView(
        reverse: true,
        child: SelectableText(
          lines.isEmpty ? t.audiobook_tts_local_log_empty : lines.join('\n'),
          style: Theme.of(
            dialogContext,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
    ),
    actions: <Widget>[
      FushiDialogAction(
        label: t.dialog_ok,
        kind: FushiDialogActionKind.primary,
        autofocus: true,
        onPressed: () => Navigator.of(dialogContext).pop(),
      ),
    ],
  ),
);
