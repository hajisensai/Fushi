/// 远端占位成员（对端有、本机还没下载的书 / 纯字幕有声书）的合集成员信息。
///
/// 远端占位卡没有本地进度，但 host 清单**自带**它那边的阅读进度与显示名
/// （[RemoteBookInfo.progressPercent] / [RemoteBookInfo.displayName]，首页「继续」早就
/// 用它们把 host 在读的书并进来）。书架合集卡的「读到第 X 卷」/ 合集进度条、合集
/// 详情页的卷号排序都读 [CollectionMemberInfo]：远端成员此前一律给 null，于是没下载
/// 的那卷读过也不算（反馈 vHa0VKme1R），详情页拿不到标题只能按成员行 entryKey（对端
/// bookKey）排，卷序成了 2、1、3（反馈 ky0eLY4LHa）。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/collections/collection_member_view.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteAudiobookInfo, RemoteBookInfo;

/// host 清单里这本书的阅读进度（0..1）；0 = 没读过 / 旧 host 没带 → null。
double? remoteBookProgressFraction(RemoteBookInfo book) =>
    book.progressPercent <= 0
    ? null
    : (book.progressPercent / 100).clamp(0.0, 1.0).toDouble();

/// 远端书占位成员的展示信息：标题用 host 的显示名（与占位卡同源），进度 / 最后
/// 阅读 / 读完取 host 清单（与首页「继续」的远端书同一判据：≥100% 算读完）。
CollectionMemberInfo remoteBookMemberInfo(
  RemoteBookInfo book, {
  Widget? cover,
}) {
  final int updatedAt = book.progressUpdatedAtMs;
  return CollectionMemberInfo(
    title: book.displayName,
    cover: cover,
    progress: remoteBookProgressFraction(book),
    lastReadAt: book.progressPercent > 0 && updatedAt > 0 ? updatedAt : null,
    completed: book.progressPercent >= 100,
  );
}

/// 纯字幕远端有声书占位成员：没有时长，不给进度比例（与本地纯字幕书同口径），
/// 但 host 听过（断点 > 0）就带上最后收听时刻。
CollectionMemberInfo remoteAudiobookMemberInfo(
  RemoteAudiobookInfo book, {
  Widget? cover,
}) {
  final int updatedAt = book.positionUpdatedAtMs;
  return CollectionMemberInfo(
    title: book.title ?? book.identity,
    cover: cover,
    lastReadAt: book.positionMs > 0 && updatedAt > 0 ? updatedAt : null,
  );
}
