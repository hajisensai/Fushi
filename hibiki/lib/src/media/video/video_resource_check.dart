import 'dart:io';

import 'package:hibiki/src/media/video/url_stream_video.dart';

/// 纯函数（TODO-897）：判断 [videoPath] 是否需要做「本地文件存在性校验」。
///
/// 视频打开链路只有两类源（[VideoHibikiPage._applyLoad]）：本地文件路径
/// （`videoPath != null`）与网络流（`mediaUri != null` / `videoPath == null`）。
/// 远端 / 流不碰文件系统、由播放内核网络直传，所以**只有本地非空、非流 URL 的
/// 路径**才需要存在性校验：
/// - `null` / 空串 ⇒ 远端 / 未知，不校验（false）；
/// - http/https 流 URL（[isPlayableStreamUrl]）⇒ 网络流，豁免（false）；
/// - 其它（本地绝对路径 / `file://` 等本地路径）⇒ 需校验（true）。
///
/// 纯字符串判定，不碰文件系统 / 网络（与 [isPlayableStreamUrl] 同源，保证流豁免
/// 判据与既有播放判据一致）。
bool videoResourceRequiresLocalCheck(String? videoPath) {
  if (videoPath == null) return false;
  final String trimmed = videoPath.trim();
  if (trimmed.isEmpty) return false;
  if (isPlayableStreamUrl(trimmed)) return false;
  return true;
}

/// 异步判定（TODO-897）：本地视频资源是否「缺失」（被移动 / 删除 / 所在盘未挂载）。
///
/// 流 / 远端 / 空路径不需校验，恒返回 false（不缺失，照常 load）。需校验时返回
/// `!await File(videoPath).exists()`——用**异步** `exists()` 不阻塞 UI 线程
/// （调用方 `_applyLoad` 已是 async）。
///
/// 注意：外接盘 / 网络盘暂时离线时 `exists()` 也返 false → 会把「盘没挂」判成缺失。
/// 这是不可避免的歧义；缓解放在 UI 层——缺失对话框中性文案 + 删除走二次确认、不
/// 默认 / 不诱导删除（避免误删用户仍想看的活条目，Never-break-userspace 红线）。
Future<bool> isLocalVideoResourceMissing(String? videoPath) async {
  if (!videoResourceRequiresLocalCheck(videoPath)) return false;
  return !await File(videoPath!.trim()).exists();
}
