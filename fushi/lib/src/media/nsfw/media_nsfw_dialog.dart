/// 作品级「NSFW」标记的一次性写入口（拍板台 w04vrhUAaX）。
///
/// 作品菜单里的 NSFW 开关已并进统一的「隐私」对话框（`media_privacy_dialog.dart`，
/// 拍板台 qiqSbvdxrk）；这里只留给刮削封面等「顺手标一下」的入口用的写函数。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';

/// 写作品自己的 NSFW 标记并给结果提示。失败时提示后重新抛出，调用方把状态拨回去。
Future<void> writeMediaNsfw(
  FushiDatabase db,
  TagHostKind kind,
  String entryKey,
  bool nsfw,
) async {
  try {
    await db.setMediaNsfw(kind, entryKey, nsfw);
  } on Object catch (error) {
    // 写失败必须明说：用户以为封面已经藏起来了、其实没有。
    FushiToast.show(
      msg: t.media_nsfw_save_failed(reason: error.toString()),
      severity: ToastSeverity.error,
    );
    rethrow;
  }
  FushiToast.show(
    msg: nsfw ? t.media_nsfw_marked_toast : t.media_nsfw_cleared_toast,
    severity: ToastSeverity.success,
  );
}
