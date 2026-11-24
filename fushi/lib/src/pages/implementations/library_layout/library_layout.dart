import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_layout.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/library_layout/material/material_library_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// 库页外壳的设计系统分派点：[spec] 描述外壳要画什么，[body] 是当前库页的
/// 内容（保活的各分区视图）。`isGlassDesign` 为真走 [AppleLibraryLayout]
/// （Cupertino 方案 A），否则走 [MaterialLibraryLayout]（M3E 原样）。
///
/// 判据只有 `isGlassDesign`：M3E 主题在任何平台（含 iPhone / Mac）都走 Material
/// 外壳，Cupertino 主题在任何平台都走 Apple 外壳。
class LibraryLayout<T extends Object> extends StatelessWidget {
  const LibraryLayout({required this.spec, required this.body, super.key});

  final LibraryChromeSpec<T> spec;
  final Widget body;

  @override
  Widget build(BuildContext context) => isGlassDesign(context)
      ? AppleLibraryLayout<T>(spec: spec, body: body)
      : MaterialLibraryLayout<T>(spec: spec, body: body);
}
