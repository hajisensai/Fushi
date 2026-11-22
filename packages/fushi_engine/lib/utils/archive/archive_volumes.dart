/// 分卷归档（7-Zip「分卷」按字节切出的 `book.7z.001`、`.002`…，zip 同理）的文件名判据。
///
/// 解包由 Rust `fushi_compute` 把第一卷及其后各卷拼成一个流来做（`archive.rs` 的
/// `volume_number`，任何归档扩展名都拼）；这里只给导入入口用，且只对 7z / zip 开口：认出
/// 第一卷、把后续卷挡在外面（它们随第一卷一起解开，不能各自再导入一次）。
library;

/// 能按字节分卷解开的归档扩展名（带点、小写）。RAR 自有分卷格式（`.part1.rar`），不在此列。
const Set<String> kSplitArchiveExtensions = <String>{'.7z', '.zip'};

final RegExp _volumeName = RegExp(r'^(.+)(\.[^.\\/]+)\.(\d{3,})$');

/// 分卷信息：[path] 形如 `<名>.<7z|zip>.<至少 3 位数字>` 时返回（去掉编号的路径、编号），
/// 否则 null。
({String archivePath, int number})? splitArchiveVolume(String path) {
  final RegExpMatch? m = _volumeName.firstMatch(path);
  if (m == null) return null;
  final String ext = m.group(2)!.toLowerCase();
  if (!kSplitArchiveExtensions.contains(ext)) return null;
  final String base = m.group(1)!;
  final int cut = base.lastIndexOf(RegExp(r'[\\/]'));
  if (base.substring(cut + 1).isEmpty) return null;
  return (archivePath: '$base${m.group(2)!}', number: int.parse(m.group(3)!));
}

/// 是分卷归档的第一卷（`.001`）：导入时把它当整个包。
bool isFirstSplitArchiveVolume(String path) =>
    splitArchiveVolume(path)?.number == 1;

/// 是分卷归档的后续卷（`.002` 起）：随第一卷一起解开，自己不单独导入。
bool isLaterSplitArchiveVolume(String path) {
  final int? number = splitArchiveVolume(path)?.number;
  return number != null && number > 1;
}
