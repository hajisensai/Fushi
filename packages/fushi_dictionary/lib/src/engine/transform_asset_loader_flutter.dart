/// Flutter 宿主的变形表资源读取：rootBundle（`assets/transforms/` 随 app 打包）。
/// 只经 `fushidicts.dart` 的 `if (dart.library.ui)` 条件 import 选中，纯 Dart
/// 宿主编译时根本不会加载本文件。
library;

import 'package:flutter/services.dart' show rootBundle;

/// 当前宿主的资源读取后端名（测试据此断言 Flutter 宿主选中了本分支）。
const String kTransformAssetBackend = 'rootBundle';

/// 按资源键从 Flutter 资源包读一份变形表。
Future<String> loadBundledTransformAsset(String assetKey) =>
    rootBundle.loadString(assetKey);
