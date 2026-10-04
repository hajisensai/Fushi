import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 启动 Fushi 时按用户设置把 Anki 桌面版拉起来（issue #1949）。
///
/// 只在主入口 `main()` 里 fire-and-forget 调一次：弹窗词典 / 悬浮词典是另外的
/// entry point，不该各自再拉一次 Anki。判据全在
/// [AnkiDesktopLauncher.autoLaunchOnStartup]；这里只负责读设置、把认出来的入口
/// 路径写回去，以及保证这条可有可无的后台动作绝不把异常冒泡到启动流程。
Future<AnkiDesktopLaunchResult?> autoLaunchAnkiDesktopOnStartup(
  BaseAnkiRepository repository,
) async {
  try {
    final AnkiSettings settings = await repository.loadSettings();
    final AnkiDesktopLaunchResult result =
        await AnkiDesktopLauncher.autoLaunchOnStartup(settings);
    final String? learned = result.learnedExecutable;
    if (learned != null) {
      await repository.updateSettings(
        (AnkiSettings s) => s.copyWith(ankiDesktopExecutable: learned),
      );
    }
    if (result.status != AnkiDesktopLaunchStatus.skipped) {
      debugPrint(
        'autoLaunchAnkiDesktop: ${result.status.name}'
        '${result.detail == null ? '' : ' (${result.detail})'}',
      );
    }
    return result;
  } on Object catch (e) {
    debugPrint('autoLaunchAnkiDesktop: failed: $e');
    return null;
  }
}
