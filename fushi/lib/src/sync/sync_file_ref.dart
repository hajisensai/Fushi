/// 同步后端通用的远端文件句柄与内部枚举。
///
/// 历史上这些类型带着 `Drive` 前缀住在 `ttu_models.dart`（ッツ wire 契约文件）
/// 里，但它们从不是ッツ契约的一部分：所有后端（Google Drive / WebDAV / Dropbox /
/// OneDrive / FTP / SFTP / hibiki 互联）都用它们描述「远端文件的定位符」，枚举也
/// 只在本 app 内部流转、从不落盘/上 wire。命名统一轮改名迁出（§1-H）。

/// 后端无关的远端文件句柄：定位符 [id] + 文件名 [name]，不含内容。
///
/// [id] 的具体形态由各后端定义（Google Drive fileId、路径式后端的路径等），
/// 调用方只把它原样传回同一后端的下载/更新原语。
class SyncFileRef {
  const SyncFileRef({required this.id, required this.name});

  final String id;
  final String name;

  factory SyncFileRef.fromJson(Map<String, dynamic> json) => SyncFileRef(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

/// 某本书远端文件夹里 progress / statistics / audioBook 元数据三件套的句柄集
/// （与 [SyncBackendFileTrioMixin] 的「三件套」同指；条目缺失 = 远端尚无该文件）。
class SyncFileTrio {
  const SyncFileTrio({this.progress, this.statistics, this.audioBook});

  final SyncFileRef? progress;
  final SyncFileRef? statistics;
  final SyncFileRef? audioBook;
}

/// 单本书云同步的方向判定（[SyncManager] 内部决策结果，不落盘）。
enum SyncDirection { importFromTtu, exportToTtu, synced }

/// 统计合并策略（本 app 内部选项，不落盘）。
enum StatisticsSyncMode { merge, replace }

/// 单本书云同步的结果分类（进度提示/汇总用，不落盘）。
enum SyncResult {
  synced,
  imported,
  exported,
  skipped,
  conflict,
}
