import 'dart:io';

import 'package:flutter/widgets.dart';

/// BUG-959：本地媒体封面统一解码上限（物理像素宽）。
///
/// 封面卡槽最宽约 200 逻辑像素，最高 dpr(3) 下约 600 物理像素，720 仍有富余且清晰；
/// 而封面源常是视频原生分辨率（1080p/4K）或 EPUB 原始封面（常 1600×2400），不降采样
/// 会整帧解码进 Flutter ImageCache（默认 100MB/1000 张）——十几张 1080p 或 3 张 4K
/// 即撑爆上限，滚动时 LRU 反复淘汰→重解码全帧，产生持续卡顿与高内存。
const int kLocalCoverDecodePixelWidth = 720;

/// 有声书迷你条等极小封面（约 36 逻辑像素）的解码上限，进一步省内存。
const int kMiniCoverDecodePixelWidth = 144;

/// 给本地文件封面 [ImageProvider] 套解码上限。
///
/// [ResizeImage] 只按 [width] 上限降采样（`allowUpscaling: false` 保证不放大、不裁切、
/// 小于上限的源原样解码），把「原生分辨率整帧」收敛到「卡槽够用的物理像素」。
/// 缺失文件由上层 `errorBuilder` / `frameBuilder` 兜底，不需要事先同步 `existsSync`。
ImageProvider resizedFileImage(
  File file, {
  int width = kLocalCoverDecodePixelWidth,
}) =>
    ResizeImage(FileImage(file), width: width, allowUpscaling: false);
