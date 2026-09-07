import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 「放弃下载」的共享编排：确认 → 删半截包 → 阶段落回 idle。
///
/// 提成库级函数与 [importDownloadedRecommendedPack] 同一条纪律：发起点有两个
/// （首页迷你条、设置 → 系统那一行），确认框漏一处就意味着一次误触抹掉几 GB 的
/// 下载进度。controller 那边只有
/// [RecommendedPackDownloadController.discardPartialDownload] 这个原语，它不弹
/// 任何 UI —— 删几 GB 要用户按，controller 不能替用户按。
///
/// 确认框走全 app 统一的 [FushiDestructiveConfirmDialog]，不自造裸 `AlertDialog`
/// （2026-07-22 UI 巡检收口过同一语义的四种实现，这里不再开第五种）。
Future<void> confirmAndDiscardRecommendedPack(
  BuildContext context,
  RecommendedPackDownloadController controller,
) async {
  if (!controller.isPaused || controller.isDeleting.value) return;
  final FushiDestructiveConfirmResult? confirmed =
      await showAppDialog<FushiDestructiveConfirmResult>(
        context: context,
        builder: (BuildContext ctx) => FushiDestructiveConfirmDialog(
          title: t.onboarding_pack_download_discard,
          message: t.onboarding_pack_discard_confirm,
        ),
      );
  if (confirmed == null) return;
  await controller.discardPartialDownload();
}
