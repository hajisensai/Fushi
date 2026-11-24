/// 导入页的设计系统分派（2026-11-24 用户拍板「Cupertino 导入页独立布局」方案 A）：
/// 书 / 漫画 / 视频 / 音乐 / 游戏的「导入」视图与查词「一本词典都没有」的空态
/// 都只建这一个 [ImportPageLayout]，按 `isGlassDesign` 分派：
///
/// - M3E 主题（任何平台）→ [MaterialImportLayout]（导入稿 v2 拼贴，原样）；
/// - Cupertino 主题 → [AppleImportLayout]（「设置」式分组列表）。
///
/// 两套共用同一份 [ImportSurfaceSpec] 与来源数据（`MediaSourcesView`），业务动作
/// 只有一份；本类只分派，不画任何东西。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/import/apple/apple_import_layout.dart';
import 'package:fushi/src/media/import/import_collage_page.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

class ImportPageLayout extends StatelessWidget {
  const ImportPageLayout({
    required this.spec,
    this.sources,
    this.onAddSource,
    this.addSourceEnabled = true,
    this.scrollable = true,
    super.key,
  });

  final ImportSurfaceSpec spec;

  /// 来源区（通常是 `MediaSourcesView(presentation: blocks)`）；null = 没有来源区
  /// （查词空态）。
  final Widget? sources;

  /// M3E 区头「＋ 添加来源」；Apple 布局里添加来源是来源组末行（由来源区自己给）。
  final VoidCallback? onAddSource;
  final bool addSourceEnabled;

  /// false = 不自带滚动（嵌进宿主页自己的滚动视图）。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return AppleImportLayout(
        spec: spec,
        sources: sources,
        scrollable: scrollable,
      );
    }
    return MaterialImportLayout(
      spec: spec,
      sources: sources,
      onAddSource: onAddSource,
      addSourceEnabled: addSourceEnabled,
      scrollable: scrollable,
    );
  }
}
