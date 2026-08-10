/// Hibiki→Fushi 迁移的**启动期显式弹窗**（改名迁移计划 P1-3）。
///
/// 为什么是弹窗而不是设置里一个入口：老包换了包名，系统层面**不可能**原地升级
/// ——不主动告知的用户会一直留在一个已停更的 app 上，直到某天发现没人修 bug 了。
/// 这不是「可发现性」问题，是「用户必须知道」问题，所以每次启动都弹，且只有
/// 「稍后」一个退出口（不给「不再提醒」——那等于允许用户永久错过迁移）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 本进程是否已经弹过。
///
/// 「每次启动都弹」= 每个进程一次，不是每次回到首页一次——后者会在用户点「稍后」
/// 后立刻再弹，变成无法使用 app 的死循环。
bool _shownThisLaunch = false;

@visibleForTesting
void resetMigrationPromptForTest() => _shownThisLaunch = false;

/// 是否该弹迁移提示（纯函数，便于单测覆盖全部组合）。
///
/// - [migrated]：已完成导出（只读态）。
/// - [fushiInstalled]：Fushi **此刻**是否装在这台设备上。
/// - [isAndroid]：跨包名迁移只存在于 Android；桌面端数据目录可直接搬，弹窗只会
///   徒增困惑。
/// - [alreadyShownThisLaunch]：本进程弹过就不再弹。
///
/// BUG-1501：判据是「迁移这件事是否已经有落点」，不是「导出过没有」。
/// 已导出**且 Fushi 还在** → 安静，首页横幅接手（原有行为）。
/// 已导出**但 Fushi 不在**（没装成 / 装完又被卸了）→ 用户此刻两头落空：旧版只读
/// 不再写入也不再更新，新版根本不存在。这和「还没迁移」一样属于必须主动告知的
/// 状态，只在首页顶上留一条横幅是不够的。
bool shouldShowMigrationPrompt({
  required bool migrated,
  required bool isAndroid,
  required bool alreadyShownThisLaunch,
  required bool fushiInstalled,
}) {
  if (!isAndroid) return false;
  if (alreadyShownThisLaunch) return false;
  if (migrated && fushiInstalled) return false;
  return true;
}

/// 启动期弹一次迁移提示。[onMigrate] 由调用方接到「打开迁移页并直接开跑」。
///
/// 弹窗**不可点外部消失**（`barrierDismissible: false`）：这是用户必须读到的一条
/// 信息，误触关掉等于没通知到。退出口只有「稍后」。
Future<void> showMigrationPromptIfNeeded(
  BuildContext context, {
  required bool migrated,
  required bool fushiInstalled,
  required String title,
  required String body,
  required String migrateLabel,
  required String laterLabel,
  required VoidCallback onMigrate,
  bool? isAndroidOverride,
}) async {
  final bool isAndroid = isAndroidOverride ?? (!kIsWeb && Platform.isAndroid);
  if (!shouldShowMigrationPrompt(
    migrated: migrated,
    isAndroid: isAndroid,
    alreadyShownThisLaunch: _shownThisLaunch,
    fushiInstalled: fushiInstalled,
  )) {
    return;
  }
  _shownThisLaunch = true;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => AlertDialog(
      icon: const Icon(Icons.drive_file_move_outlined),
      title: Text(title),
      content: Text(body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(laterLabel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            onMigrate();
          },
          child: Text(migrateLabel),
        ),
      ],
    ),
  );
}
