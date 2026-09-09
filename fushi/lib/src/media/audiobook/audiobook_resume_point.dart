/// 阅读器开书时「阅读进度 vs 有声书进度」的起点仲裁（BUG-2328）。
///
/// 两份进度各自独立持久化、各带写入时刻：阅读进度是 `ReaderPositions.updatedAt`
/// （滚动 debounce 落库），有声书进度是 `audiobook_pos_at_<key>` 偏好（播放中每整秒
/// + 暂停/停止时写）。退书后台听书、书架小播放器听书这类只推进音频的路径不会碰阅读
/// 进度，所以重开书时不能无条件偏向阅读进度——谁更新谁说了算（同一 LWW 语义与互联
/// 同步 BUG-471 一致）。
///
/// 严格较新才由音频胜出：相等（含双方都没记录的 0 vs 0）仍走阅读进度，与修复前
/// 「有存档就按存档」的默认一致；从没写过时间戳的老数据（0）也不会反过来压掉存档。
bool audiobookResumeWinsOverReader({
  required int readerUpdatedAt,
  required int audioUpdatedAt,
}) {
  return audioUpdatedAt > readerUpdatedAt;
}
