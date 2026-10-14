/// 复习牌组列表「导入」动作的入口。
///
/// 占位：真实实现（`SrsImportService`，Anki .apkg / .colpkg 导入）另行提供后替换
/// 本函数体；调用点（牌组列表页的顶栏动作）不用改。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/utils.dart';

/// 打开导入流程。当前只提示「即将提供」。
Future<void> openSrsImport(BuildContext context, WidgetRef ref) async {
  FushiToast.show(msg: t.srs_import_coming_soon);
}
