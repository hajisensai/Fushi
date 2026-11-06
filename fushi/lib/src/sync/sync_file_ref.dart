/// 同步后端通用的远端文件句柄与内部枚举。
///
/// 历史上这些类型带着 `Drive` 前缀住在 `ttu_models.dart`（ッツ wire 契约文件）
/// 里，但它们从不是ッツ契约的一部分：所有后端（Google Drive / WebDAV / Dropbox /
/// OneDrive / FTP / SFTP / Fushi 互联）都用它们描述「远端文件的定位符」，枚举也
/// 只在本 app 内部流转、从不落盘/上 wire。命名统一轮改名迁出（§1-H）。

/// 后端无关的远端文件句柄：定位符 [id] + 文件名 [name]，不含内容。
///
/// [id] 的具体形态由各后端定义（Google Drive fileId、路径式后端的路径等），
/// 调用方只把它原样传回同一后端的下载/更新原语。
class SyncFileRef {
  const SyncFileRef({required this.id, required this.name});

  final String id;
  final String name;

  factory SyncFileRef.fromJson(Map<String, dynamic> json) =>
      SyncFileRef(id: json['id'] as String, name: json['name'] as String);
}

/// 某本书远端文件夹里 progress / statistics / audioBook 元数据三件套的句柄集
/// （与 [SyncBackendFileTrioMixin] 的「三件套」同指；条目缺失 = 远端尚无该文件）。
class SyncFileTrio {
  const SyncFileTrio({
    this.progress,
    this.statistics,
    this.audioBook,
    this.fileNames,
  });

  final SyncFileRef? progress;
  final SyncFileRef? statistics;
  final SyncFileRef? audioBook;

  /// 得出这组三件套的那次列举里，书文件夹下**全部**文件（非文件夹）的名字；
  /// `null` = 列举方没给出完整清单（测试替身 / 分页没取完），调用方要自己再列。
  ///
  /// jHQpTfjrNB：三件套本来就是从一次整目录列举里挑出来的，旧形状只留下三个
  /// 句柄、把其余文件名丢掉，于是同一轮里补传书文件（`.epub` / sidecar 在不在）和
  /// 有声书包阶段（`.fushiaudio` 在不在）又各自对同一个文件夹重列 / 逐个探针——
  /// 没有快照的后端（WebDAV / OneDrive / FTP / SFTP）每本书每轮多付 1–3 次往返。
  /// 名字与三件套同源（同一次回包），不引入任何需要被信任的中间结论。
  final Set<String>? fileNames;
}

/// 单本书云同步的方向判定（[SyncManager] 内部决策结果，不落盘）。
enum SyncDirection { importFromTtu, exportToTtu, synced }

/// 统计合并策略（本 app 内部选项，不落盘）。
enum StatisticsSyncMode { merge, replace }

/// 单本书云同步的结果分类（进度提示/汇总用，不落盘）。
enum SyncResult { synced, imported, exported, skipped, conflict }
