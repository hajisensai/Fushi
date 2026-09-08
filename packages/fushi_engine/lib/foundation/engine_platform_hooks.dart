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

/// 删文件**之前**释放图片缓存对它的引用（Windows 上被解码器持有的文件句柄会让
/// delete 失败）。语义是「锁释放提示」，实现可以比 [evictImageCacheForFile] 重
/// （app 侧整表 clear）；只在删除路径用，别拿它做写后驱逐。
Future<void> Function(File file) releaseImageCacheBeforeDelete = (File _) async {};
