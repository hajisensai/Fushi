/// 封面来源解析里「不靠书架模型」的那两路：远端（互联）封面与本机文件。
///
/// [resolveMediaCoverImage]（`media_cover_source.dart`）的书分支要 `AppModel` /
/// `MediaSource`，整个文件因此落在 lib/ 的大 import 环里；游戏 / 视频这类只有本机
/// 路径或远端地址的显示点直接调本文件，就不用为一条本机路径把 AppModel 拖进来
/// （`test/build/import_cycle_guard_test.dart`）。优先级与解码上限仍只在这里写一次，
/// [resolveMediaCoverImage] 的非书分支就是转调本函数。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth, resizedFileImage;

/// 远端封面（[remoteUrl] + [remoteFetcher] 齐备）优先，其次本机文件
/// [localPath]；都没有返回 null。
///
/// 远端封面与本机文件**对称**套解码上限（BUG-959 的远端半边）：host 下发的
/// 封面常是 Jellyfin / Emby 原图（1000×1500 起步），整帧解进 ImageCache——远端
/// 库页 / 剧集面板几十张封面就把 100MB 上限撑爆，滚动时反复淘汰重解码，iOS 上
/// 是低内存被杀的主因之一。[ResizeImage] 把 targetWidth 经 decode 回调交给
/// `RemoteCoverImage._loadAsync`，磁盘 / 网络字节不变、只降解码尺寸。
///
/// **不做 `existsSync`**：文件缺失由渲染层的 `errorBuilder` 兜底（见
/// [resizedFileImage] 注释）。
ImageProvider? resolveStandaloneCoverImage({
  String? localPath,
  String? remoteUrl,
  RemoteCoverFetcher? remoteFetcher,
  String? remoteCacheKey,
  int decodeWidth = kLocalCoverDecodePixelWidth,
}) {
  if (remoteUrl != null && remoteUrl.isNotEmpty && remoteFetcher != null) {
    return ResizeImage(
      RemoteCoverImage(remoteUrl, remoteFetcher, cacheKey: remoteCacheKey),
      width: decodeWidth,
      allowUpscaling: false,
    );
  }
  if (localPath != null && localPath.isNotEmpty) {
    return resizedFileImage(File(localPath), width: decodeWidth);
  }
  return null;
}
