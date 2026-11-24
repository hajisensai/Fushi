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
  const LibraryLayout({
    required this.spec,
    required this.body,
    this.materialBuilder,
    super.key,
  });

  final LibraryChromeSpec<T> spec;
  final Widget body;

  /// 宿主自带的 M3E 外壳（null = 通用的 [MaterialLibraryLayout]）。音乐库的 M3E
  /// 页头大字把二级页签与推荐来源页签同排进大字行、不叠嵌套工具区，与通用外壳
  /// 版面不同；为保持 M3E 像素不变由宿主原样给出。Apple 外壳恒由 [spec] 画。
  final WidgetBuilder? materialBuilder;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return AppleLibraryLayout<T>(spec: spec, body: body);
    }
    final WidgetBuilder? material = materialBuilder;
    return material != null
        ? material(context)
        : MaterialLibraryLayout<T>(spec: spec, body: body);
  }
}
