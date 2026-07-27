/// 封面**显示侧**统一来源解析（读路径）。
///
/// # 为什么需要这个文件
///
/// 此前「一张封面从哪来」是在**每个显示点各写一遍**的：远端就 `RemoteCoverImage`、
/// 视频/游戏就 `File(path).existsSync() ? Image.file : 占位`、书就
/// `getDisplayThumbnailFromMediaItem`。同一段四路分支散在约 20 个文件里，后果是
/// 新增媒体种类要挨个改，漏掉一处就是「这里有封面那里没有」——用户报的
/// 「剧集列表少了封面」「活动里没有封面」都是这么来的。
///
/// 本文件只回答**一个**问题：给定媒体身份，封面的 [ImageProvider] 是什么。
///
/// # 三者分工（不要混淆）
///
/// - **写入**：`MediaCoverService`（选图 / 覆盖 / 落盘 / 缓存驱逐）。
/// - **来源解析**：本文件。
/// - **渲染**：`PosterCoverImage`（竖图 cover / 横图模糊垫底 + contain），它明确
///   「不关心来源」，接收本文件解析出的 provider。
///
/// # 互联（远端）封面
///
/// 远端封面**不是**另一条平行世界：它只是本解析器的一个来源分支
/// （[RemoteCoverImage] + [RemoteCoverFetcher] + 稳定 cacheKey 的磁盘缓存）。
/// 调用方不该再自己判断「这条是不是远端」。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart' show MediaKind;

import 'package:hibiki/src/media/media_item.dart' show MediaItem;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki/src/sync/remote_cover_image.dart';
import 'package:hibiki/src/utils/cover_image.dart'
    show kLocalCoverDecodePixelWidth, resizedFileImage;

/// 解析一条媒体的封面图源；返回 null = 无封面可显示，调用方画占位
/// （占位图标用 [mediaCoverFallbackIcon]）。
///
/// 优先级（**刻意固定**，调用方不得自己另排）：
/// 1. [book] 非空 → 走书自己的 override 缩略图链（`MediaSource` 内部已处理
///    override 封面 / 内嵌封面 / [fallbackUrl] 三级），书的链路自成体系不拆开；
/// 2. [remoteUrl] + [remoteFetcher] 齐备 → [RemoteCoverImage]（互联/远端）；
/// 3. [localPath] 非空 → 本机文件（视频抽帧 / 游戏目录图或 exe 图标 / 刮削下载）；
/// 4. 都没有 → null。
///
/// **不做 `existsSync`**：那是每帧一次同步 IO，而文件缺失由渲染层的
/// `errorBuilder` 兜底即可（见 [resizedFileImage] 注释）。
///
/// 本机文件恒过 [resizedFileImage] 套解码上限——整帧原生分辨率解进内存只为画一个
/// 卡槽是纯浪费；[decodeWidth] 只在调用方确知需要更大图时才调。
ImageProvider? resolveMediaCoverImage({
  required MediaKind kind,
  MediaItem? book,
  AppModel? appModel,
  String? localPath,
  String? remoteUrl,
  RemoteCoverFetcher? remoteFetcher,
  String? remoteCacheKey,
  String? fallbackUrl,
  int decodeWidth = kLocalCoverDecodePixelWidth,
}) {
  if (book != null && appModel != null) {
    return book
        .getMediaSource(appModel: appModel)
        .getDisplayThumbnailFromMediaItem(
          appModel: appModel,
          item: book,
          fallbackUrl: fallbackUrl,
        );
  }
  if (remoteUrl != null && remoteUrl.isNotEmpty && remoteFetcher != null) {
    return RemoteCoverImage(remoteUrl, remoteFetcher, cacheKey: remoteCacheKey);
  }
  if (localPath != null && localPath.isNotEmpty) {
    return resizedFileImage(File(localPath), width: decodeWidth);
  }
  return null;
}

/// 无封面时的占位图标——**按媒体种类**，不是所有东西都画一本书。
IconData mediaCoverFallbackIcon(MediaKind kind) => switch (kind) {
      MediaKind.video => Icons.movie_outlined,
      MediaKind.game => Icons.videogame_asset_outlined,
      MediaKind.epub || MediaKind.srt => Icons.menu_book_outlined,
    };
