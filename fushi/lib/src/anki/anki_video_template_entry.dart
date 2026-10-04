import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi/src/anki/anki_video_template_page.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/mining/mining_image_mode_target.dart'
    show onSynchronizedClipTemplateFallback;

/// 已提示过「未适配视频、改用 gif」的笔记类型名（JSON 字符串数组）。每个笔记类型只
/// 打断一次：之后的降级照常静默发生，设置页那行仍持续显示未适配。
const String kAnkiVideoTemplateFallbackNoticedKey =
    'anki_video_template_fallback_noticed';

/// 打开「视频播放适配」页。设置页入口与制卡降级提示的「去适配」共用这一处。
Future<void> openAnkiVideoTemplate(
  BuildContext context, {
  required AnkiViewModel vm,
  required AnkiSettings settings,
}) async {
  final AnkiNoteType? noteType = settings.selectedNoteType;
  if (noteType == null) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AnkiVideoTemplatePage(
        service: vm.videoTemplateService,
        modelName: noteType.name,
        initialFieldMappings: settings.fieldMappings,
        onApplied: vm.refreshSettingsFromStore,
      ),
    ),
  );
}

/// 第一次为 [noteTypeName] 提示时返回 true 并记下；之后恒 false。
Future<bool> claimAnkiVideoTemplateFallbackNotice(
  PrefStore prefs,
  String noteTypeName,
) async {
  final Set<String> noticed = _readNoticed(prefs);
  if (!noticed.add(noteTypeName)) return false;
  await prefs.setPref(
    kAnkiVideoTemplateFallbackNoticedKey,
    jsonEncode(noticed.toList()),
  );
  return true;
}

Set<String> _readNoticed(PrefStore prefs) {
  final Object? raw = prefs.getPref(
    kAnkiVideoTemplateFallbackNoticedKey,
    defaultValue: '',
  );
  if (raw is! String || raw.isEmpty) return <String>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is List) return decoded.whereType<String>().toSet();
  } on FormatException catch (error) {
    engineLog.logDiagnostic('Anki.synchronizedVideo.noticeState', error);
  }
  return <String>{};
}

/// 装配制卡降级提示：每个笔记类型第一次因模板不渲染同步片段而改走 gif 时，弹窗说明
/// 并给出「去适配」。只在主 entry point 装（需要主导航器）。[prefs] 是惰性取值：装配
/// 发生在 `AppModel.initialise()` 之前，偏好仓库那时还没建好；制卡时它一定已就绪。
void installAnkiVideoTemplateFallbackNotice({
  required GlobalKey<NavigatorState> navigatorKey,
  required PrefStore Function() prefs,
}) {
  bool showing = false;
  onSynchronizedClipTemplateFallback = (String noteTypeName) async {
    if (showing) return;
    if (!await claimAnkiVideoTemplateFallbackNotice(prefs(), noteTypeName)) {
      return;
    }
    final BuildContext? context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    showing = true;
    try {
      await _showFallbackDialog(context, noteTypeName);
    } finally {
      showing = false;
    }
  };
}

Future<void> _showFallbackDialog(
  BuildContext context,
  String noteTypeName,
) async {
  final bool? adapt = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog.adaptive(
      title: Text(t.anki_video_template_fallback_title),
      content: Text(
        t.anki_video_template_fallback_body(noteType: noteTypeName),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: dialogContext,
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(t.anki_video_template_fallback_dismiss),
        ),
        adaptiveDialogAction(
          context: dialogContext,
          isDefaultAction: true,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(t.anki_video_template_fallback_adapt),
        ),
      ],
    ),
  );
  if (adapt != true || !context.mounted) return;
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final AnkiViewModel vm = container.read(ankiViewModelProvider.notifier);
  await vm.refreshSettingsFromStore();
  if (!context.mounted) return;
  await openAnkiVideoTemplate(context, vm: vm, settings: vm.settings);
}
