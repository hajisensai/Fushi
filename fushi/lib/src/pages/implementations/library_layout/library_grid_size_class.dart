// 库页网格尺寸档的判定，单独成叶子文件：音乐库等只要尺寸档的调用方不必 import
// `library_view_options.dart`（它挂着筛选面板 / 标签栏，在 lib/ 的大 import 环里，
// 见 `test/build/import_cycle_guard_test.dart`）。`library_view_options.dart` 原样
// re-export。

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 库页网格当前所在的尺寸档：按**真实**宽度（[windowSizeClassReal]）判，界面
/// 缩放不会把手机推进 medium 档、也不会换掉用户在这一档选的列数。
WindowSizeClass libraryGridSizeClassOf(BuildContext context) =>
    windowSizeClassReal(
      MediaQuery.sizeOf(context).width,
      FushiAppUiScale.of(context),
    );
