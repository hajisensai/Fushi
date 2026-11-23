/// 截屏识字「制卡时框选」（拍板 EuOLprw_dV 选 b）：用户想让卡图带上所点文字旁边的
/// 发帖人、时间等上下文，一键「+」只会自动裁到文本块。偏好
/// [PreferencesRepository.screenOcrCardFrameOnMine] 开着时，每次「+」先推出漫画同款
/// 全屏框选页（[MangaCropFullscreenPage]，截图模式），预选框就是一键「+」原本的
/// 自动裁切框，用户可改成整张截图 / 自定义框 / 不要图，也能打码。
///
/// 只出「卡图怎么取」这一组覆盖项（crop / 打码 / 不要图），与「高级制卡」对话框里
/// 截图分区确认后的那一组同形，交给同一个 [resolveScreenOcrCardImagePlan]。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/floating_ball/screen_ocr_card_image.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart'
    show AdvancedMiningCapabilities, AdvancedMiningSections;
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart'
    show AdvancedMiningController;
import 'package:fushi/src/mining/advanced_mining/advanced_mining_manga_panels.dart'
    show MangaCropFullscreenPage;
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;
import 'package:material_ui/material_ui.dart';

/// 这次制卡要不要先框选：有卡图来源、两个偏好都开着，且这次请求还没带卡图选择
/// （「高级制卡」对话框里已经框过 / 选了「不要」的不再弹）。
bool screenOcrCardFrameNeeded({
  required bool cardImageEnabled,
  required bool frameOnMine,
  required MiningRequestOverrides? overrides,
}) =>
    cardImageEnabled &&
    frameOnMine &&
    overrides?.crop == null &&
    overrides?.omitImage != true;

/// 把框选结果 [frame] 并进这次请求原有的覆盖项 [base]（例如应用外查词卡「调整句子
/// 音频」拖出的起止偏移），卡图三项以框选为准。
MiningRequestOverrides mergeScreenOcrCardFrame(
  MiningRequestOverrides? base,
  MiningRequestOverrides frame,
) {
  final MiningRequestOverrides from = base ?? const MiningRequestOverrides();
  return from.copyWith(
    omitImage: frame.omitImage,
    crop: frame.crop,
    clearCrop: frame.crop == null,
    mosaic: frame.mosaic,
  );
}

/// 推出截图框选页，等用户框好。返回卡图覆盖项（crop / 打码 / 不要图）；用户点「×」
/// 或系统返回时返回 null——这张卡不制。图还没读出来就点了「制卡」时没有框，结果的
/// crop 为 null，制卡退回自动裁切（与一键「+」同一张图）。
Future<MiningRequestOverrides?> pickScreenOcrCardFrame(
  BuildContext context,
  ScreenOcrCardImage source,
) async {
  final AdvancedMiningController controller = AdvancedMiningController(
    AdvancedMiningCapabilities(
      matched: '',
      sections: AdvancedMiningSections(
        mangaImage: screenOcrAdvancedMiningImageSection(source),
      ),
      // 框选页自己不制卡：确认结果由调用方读控制器后走原来的制卡路径。
      onConfirm: (MiningRequestOverrides _, {String? wordAudioUrl}) async =>
          false,
    ),
  );
  try {
    unawaited(controller.load());
    final bool kept = await MangaCropFullscreenPage.open(
      context,
      controller,
      confirmLabel: t.screen_ocr_card_frame_confirm,
    );
    if (!kept) return null;
    final MiningRequestOverrides picked = controller.buildOverrides();
    return MiningRequestOverrides(
      omitImage: picked.omitImage,
      crop: picked.crop,
      mosaic: picked.mosaic,
    );
  } finally {
    controller.dispose();
  }
}
