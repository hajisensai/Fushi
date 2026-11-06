/// 本地备份导出物文件名口径。存储页与导出前清扫共用，避免一边展示、一边认不出。
///
/// 形状 = `BackupService.defaultFilename` 产出的 `fushi-backup-<日期>.fushi.zip`
/// （`hibiki-backup-*.hibiki.zip` 是改名前的老包）。
///
/// **刻意用「前缀 + 后缀」双重限定，而不是只认 `.fushi.zip`**：临时目录里还可能躺着
/// 推荐词典包 `fushi-recommended.fushi.zip` 这类同后缀、但绝不该被当成备份清掉的文件。
/// 这条理由必须住在真相源这里——它以前留在 `backup.part.dart` 的清扫函数头上，正则搬
/// 过来时被落下了，于是唯一定义这个口径的地方反而不知道自己为什么长这样。
final RegExp backupArchiveNamePattern = RegExp(
  r'^(fushi|hibiki)-backup-.*\.(fushi|hibiki)\.zip$',
);

bool isBackupArchiveName(String name) =>
    backupArchiveNamePattern.hasMatch(name);
