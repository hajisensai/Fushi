import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 远端书 / 有声书下载的临时落点：`<root>/<identity 摘要>/<fileName>`（BUG-3337）。
///
/// [identity] 必须是**下载任务的身份**（[InterconnectDownloadManager] 的任务键，
/// 如 `book:<downloadId>` / `srt:<uid>`）——管理器按它去重，同一身份同一时刻至多
/// 一个任务在跑，所以「一个身份一个落点」就保证了并发任务之间互不共享文件；同一身份
/// 的重试仍落在同一路径上，`.part` 续传照常接得上。
///
/// 此前落点只按书名派生（`_safeRemoteBookKey`：非 ASCII 一律打成 `_`），日文书名
/// 大面积撞成同一个 `_.epub`：同时点几本，几条下载往同一个 `.part` 里写、同一个
/// `.part.etag` 互相顶掉，导入读到的是拼坏的 zip（实测日志 `Could not find End of
/// Central Directory Record`），甚至把 A 书的字节当 B 书入库。
///
/// [fileName] 原样作为 basename：导入器拿它当无标题 EPUB 的回落书名与 `epubPath`，
/// 区分身份只靠父目录，不改变任何已落库的观察面。
File remoteDownloadTempFile({
  required Directory root,
  required String identity,
  required String fileName,
}) {
  final String bucket = sha1
      .convert(utf8.encode(identity))
      .toString()
      .substring(0, 16);
  return File(p.join(root.path, bucket, fileName));
}
