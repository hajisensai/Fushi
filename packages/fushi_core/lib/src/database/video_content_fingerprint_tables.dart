import 'package:drift/drift.dart';

// ── video_content_fingerprints（schema v165）────────────────────────────────
//
// 视频「搬家」识别的内容指纹（拍板台 design-nmv-video-move-fingerprint，清单
// gap-scanner-6 的视频一半）。
//
// 视频的 `book_uid` 由文件名派生（`video/<文件名>`），同名文件挪了位置后，来源扫描要
// 判断「这个新路径上的文件是不是旧行原来那个文件」。此前只有两条间接证据：规格缓存
// 里记过的字节数，或连着对得上的两层目录名（BUG-4820）——没探过规格、目录又改了名的
// 真搬家认不出（另建 `X (2)`），名单外的通用目录名连着两层撞上仍可能把进度绑到别的剧
// 上。这张表在文件**还在原处时**记下它的内容指纹，搬家后拿新文件算一次对比，同一个
// 文件才认。
//
// 身份是 `book_uid`，不是路径：
// - 搬家后旧路径已经没有文件，要按旧行取「它原来那个文件」的指纹；
// - 不存路径就不进数据根迁移的路径改写清单；
// - 文件原地被换掉由 [fileSizeBytes] / [fileModifiedAt] 判失效（与
//   `video_file_specs` / `video_theme_song_spans` 同一组判据），重扫时重算。
//
// **纯缓存**、设备本地（不进备份 / 同步）：另一台设备上同一个 `book_uid` 可能是另一份
// 片源，拿过去只会让搬家判据误判「不是同一个文件」。删视频时 `deleteVideoBooks` 同
// 事务清掉。
@DataClassName('VideoContentFingerprintRow')
class VideoContentFingerprints extends Table {
  /// `video_books.book_uid`。**没有外键**：设备本地表在覆盖恢复后按
  /// `INSERT … SELECT * FROM devbak` 原样回灌，挂外键会让「备份里已没有这部视频」的
  /// 一行把整批设备本地表的回灌打断（同 `video_theme_song_spans`）。
  TextColumn get bookUid => text()();

  /// 算指纹当时的文件大小（字节）：失效判据，也是同一性判据的一部分（大小不等必不是
  /// 同一个文件）。
  IntColumn get fileSizeBytes => integer()();

  /// 算指纹当时的文件修改时刻（毫秒）：失效判据。
  IntColumn get fileModifiedAt => integer()();

  /// 内容指纹（带算法前缀，见引擎 `video_content_fingerprint.dart`）：
  /// `osh:<16 位十六进制>`（OpenSubtitles 文件哈希：大小 + 首尾各 64 KiB）或
  /// `sha256:<64 位十六进制>`（整文件 SHA-256：不足 128 KiB 的小文件当场算，大文件由
  /// 后台把 `osh:` 升级而来）。`osh:` 相同不足以认定搬家。
  TextColumn get fingerprint => text()();

  /// 本行写入时刻（毫秒）。
  IntColumn get computedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{bookUid};
}
