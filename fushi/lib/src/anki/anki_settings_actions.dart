import 'dart:io';

import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankiconnect_port_repair.dart';
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show Dictionary, JapaneseLanguage;

/// Anki 设置页里「无界面部分」的业务动作与文案映射。
///
/// 这些逻辑原本是 `AnkiSettingsBody` State 的私有方法，只能经 widget 触发；控制通道
/// （`fushi_cli config run`，见 `ctl_settings_body_anki.dart`）需要在没有 BuildContext /
/// 对话框的前提下执行**同一份**业务，所以抽成顶层函数：设置页与控制通道各自只负责
/// 「怎么呈现结果」，不再各写一套业务。

/// [repairAnkiConnectPort] 的结果。
class AnkiPortRepairOutcome {
  const AnkiPortRepairOutcome({this.port, this.status});

  /// 选中的新端口；null = 本机找不到空闲端口，什么都没改。
  final int? port;

  /// Anki 插件配置的写入结果；[port] 为 null 时也为 null。
  final AnkiConnectPortWriteStatus? status;
}

/// 挑一个本机空闲端口，同时写进 Anki 的 AnkiConnect 插件配置和本 app 设置。
///
/// 两处都写才算改完：AnkiConnect 的监听端口只由插件配置 `webBindPort` 决定，app 这边
/// 只是去连它。找不到插件配置时**仍然**改本 app 的端口（把用户留在「两边都是旧端口」
/// 的状态等于这次操作什么也没发生），由 [ankiPortRepairMessage] 如实提示去 Anki 里补改。
Future<AnkiPortRepairOutcome> repairAnkiConnectPort(
  AnkiViewModel vm,
  AnkiSettings settings,
) async {
  // 排掉当前端口：调用这个功能的前提就是它不好使，把它选回来等于没动。
  final int? port = await findFreeAnkiConnectPort(
    exclude: settings.ankiConnectPort,
  );
  if (port == null) return const AnkiPortRepairOutcome();
  final AnkiConnectPortWriteResult result = await writeAnkiConnectAddonPort(
    port,
  );
  await vm.updateAnkiConnectPort(port.toString());
  return AnkiPortRepairOutcome(port: port, status: result.status);
}

/// [repairAnkiConnectPort] 结果的用户可读文案。
String ankiPortRepairMessage(AnkiPortRepairOutcome outcome) {
  final int? port = outcome.port;
  if (port == null) return t.anki_connect_port_auto_fix_none;
  return switch (outcome.status) {
    AnkiConnectPortWriteStatus.updated => t.anki_connect_port_auto_fix_done(
      port: port,
    ),
    _ => t.anki_connect_port_auto_fix_manual(port: port),
  };
}

/// 打开/关闭「启动 Fushi 时自动启动 Anki」。
///
/// 打开开关时若本平台必须有路径而还没有，先试着从运行中的 Anki 认出来；认不出就返回
/// true（调用方提示去选路径——开关照样打开，路径补上后下次启动即生效）。
Future<bool> applyAutoLaunchAnkiDesktop(
  AnkiViewModel vm,
  AnkiSettings settings,
  bool value,
) async {
  await vm.setAutoLaunchAnkiDesktop(value);
  if (!value || settings.ankiDesktopExecutable.isNotEmpty) return false;
  if (!Platform.isWindows) return false;
  final String? detected = AnkiDesktopLauncher.detectRunningExecutable();
  if (detected != null) {
    await vm.setAnkiDesktopExecutable(detected);
    return false;
  }
  return true;
}

/// 从运行中的 Anki 认出入口程序并写进设置；认不出返回 null。
Future<String?> detectAndStoreAnkiExecutable(AnkiViewModel vm) async {
  final String? detected = AnkiDesktopLauncher.detectRunningExecutable();
  if (detected == null) return null;
  await vm.setAnkiDesktopExecutable(detected);
  return detected;
}

/// 启动 Anki 桌面版；顺带把这次认出来的入口程序写回设置。
Future<AnkiDesktopLaunchResult> launchAnkiDesktopAndLearn(
  AnkiViewModel vm,
  AnkiSettings settings,
) async {
  final AnkiDesktopLaunchResult result = await AnkiDesktopLauncher.launch(
    settings,
  );
  final String? learned = result.learnedExecutable;
  if (learned != null) await vm.setAnkiDesktopExecutable(learned);
  return result;
}

String ankiLaunchMessage(AnkiDesktopLaunchResult result) {
  switch (result.status) {
    case AnkiDesktopLaunchStatus.launched:
      return t.anki_desktop_launch_started;
    case AnkiDesktopLaunchStatus.alreadyRunning:
      return t.anki_desktop_launch_already_running;
    case AnkiDesktopLaunchStatus.notConfigured:
      return t.anki_desktop_launch_not_configured;
    case AnkiDesktopLaunchStatus.skipped:
    case AnkiDesktopLaunchStatus.failed:
      return t.anki_desktop_launch_failed(error: result.detail ?? '');
  }
}

String ankiAddonInstallMessage(AnkiAddonInstallResult result) {
  switch (result.status) {
    case AnkiAddonInstallStatus.handedToAnki:
      return t.anki_connect_addon_handed;
    case AnkiAddonInstallStatus.ankiNotRunning:
      return t.anki_connect_addon_anki_not_running;
    case AnkiAddonInstallStatus.downloadFailed:
      return t.anki_connect_addon_download_failed(error: result.detail ?? '');
    case AnkiAddonInstallStatus.invalidPackage:
      return t.anki_connect_addon_invalid;
    case AnkiAddonInstallStatus.launchFailed:
      return t.anki_connect_addon_launch_failed(error: result.detail ?? '');
  }
}

/// 手动备份的提示文案：顺带告诉用户按保留策略清理了几份旧备份（删除不可逆，必须让
/// 用户看得见结果）。
String lapisBackupMessage(LapisBackupOutcome? outcome) {
  if (outcome == null) return t.anki_lapis_not_found;
  if (outcome.prunedCount == 0) {
    return t.anki_lapis_backup_done(path: outcome.file.path);
  }
  return t.anki_lapis_backup_done_pruned(
    path: outcome.file.path,
    count: '${outcome.prunedCount}',
  );
}

/// 重排弹窗 / 控制通道可选的词频词典名：引擎当前装载的、且没被隐藏的。
/// 隐藏的词频词典根本不进引擎（`AppModel.bucketDictPaths`），列表只给已装载的。
List<String> loadedFrequencyDictionaryNames(AppModel appModel) {
  return appModel.freqDictionaries
      .where((Dictionary d) => !d.isHidden(JapaneseLanguage.instance))
      .map((Dictionary d) => d.name)
      .toList();
}
