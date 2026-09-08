/// 引擎里零星的「一行级」平台副作用装配点。
///
/// 这些副作用在无头进程里没有对应物（没有图片缓存、没有 UI），默认 no-op；
/// Flutter app 在 `main()` 装配真实现。每个钩子都只有一个调用点，加钩子前先
/// 问「能不能把这行删掉」，能删就别加。
library;

import 'dart:io';

/// 删封面文件前让宿主先释放对该文件的图片缓存/句柄（Windows 上 `FileImage`
/// 持有的句柄会让 `File.delete` 失败）。app 装 `PaintingBinding.imageCache` 清理；
/// 服务端 no-op。
Future<void> Function(File file) evictImageCacheForFile = (File _) async {};
