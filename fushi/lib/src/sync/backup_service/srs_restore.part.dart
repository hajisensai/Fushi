part of '../backup_service.dart';

// 还原（覆盖 / 合并）里的复习数据（G11-4；交接说明「G11-4」一节，规划 §1.9、D34）。
//
// 复习库是新代库 `srs4.db`（内核独占）。还原只经内核命令写它，**从不打开、删除或替换协议 3 的 `srs.db`**：迁移之后
// 那是原位封存的无损回退副本。
//
// - **覆盖还原**（替换语义，D34「空库加并入」）：在 `<库目录>/srs-restore-staged/` 新建一份空的新代库，把备份的复习
//   数据全部落进去（[_stageSrsRestore]）；任何一步失败就删掉暂存目录、原样抛错，本机什么都没动。主库换好之后
//   [_swapInStagedSrsLibrary]：本机的 `srs4.db` 改名成 `srs4.db.pre-restore-<时间>`（回退副本，不删），暂存库改名到位。
//   崩溃后启动恢复按 sidecar 的 `srs` 键重放（幂等）。
// - **合并还原**：主库合并提交之后，把备份的复习数据逐份落进本机库（G11-3 `import` / `legacy_backup_import`，先
//   `collection_adopt` 认领）。并入另一个复习库、记下新的旧 profile 标识 / 设备公钥要用户确认：没确认的那一份不落，
//   报告给调用方。
//
// 备份里的三种形态（[_prepareSrsRestoreUnits]）：新形态 `srs/manifest.json` + `srs/<n>.bin`；协议 3 的 `srs.db` 条目；
// 2026-10-23 之前 SRS 表在主库条目里（v1 事件，写成 JSONL 交给内核）。

/// 本机复习库此刻不能接受还原（还没迁移到新代 / 别的进程在迁移 / 迁移失败或只剩封存的旧库 / 打不开）：还原在动任何
/// 文件之前拒绝，本机什么都没动。用户先在复习页完成迁移（或取消勾选「复习」只还原其余内容）。
class SrsRestoreBlockedException implements Exception {
  const SrsRestoreBlockedException(this.reason);

  /// 代际状态的线上名（[SrsGenState.wire]）或打开失败的原因。
  final String reason;

  @override
  String toString() =>
      'SrsRestoreBlockedException: the review library on this device cannot '
      'take a restore right now ($reason); nothing was changed';
}

/// 还原覆盖新代库时的暂存目录名（与主库同目录，换库是同盘改名）。
const String _srsStagedDirName = 'srs-restore-staged';

/// 覆盖还原的暂存目录。
String _srsStagedDir(String dbDirectory) =>
    p.join(dbDirectory, _srsStagedDirName);

/// 覆盖还原换下来的本机新代库的回退副本名（[stamp] 是还原开始的时间）。
String _srsRollbackName(DateTime stamp) {
  String two(int v) => v.toString().padLeft(2, '0');
  final DateTime t = stamp.toUtc();
  return '$kSrsGen4DatabaseFileName.pre-restore-'
      '${t.year}${two(t.month)}${two(t.day)}T${two(t.hour)}${two(t.minute)}'
      '${two(t.second)}Z';
}

/// 解好、待落库的复习数据（工作目录随 [dispose] 删掉）。
final class _SrsRestoreUnits {
  _SrsRestoreUnits(this.work, this.units);

  final Directory work;
  final List<SrsBackupLandUnit> units;

  /// 备份里带复习数据的 profile（落库之前对 profile 的口径）。
  List<SrsBackupProfile> get profiles => <SrsBackupProfile>[
    for (final SrsBackupLandUnit u in units) ...u.profiles,
  ];

  Future<void> dispose() async {
    try {
      if (work.existsSync()) await work.delete(recursive: true);
    } on FileSystemException catch (e) {
      // 临时目录在系统临时区，删不掉（Windows 句柄滞后）留给系统清理，不影响还原结果。
      debugPrint('srs restore: temp dir not removed: $e');
    }
  }
}

/// 本机复习库能不能接受还原（[SrsRestoreBlockedException]）。只看代际状态（内核按磁盘上的文件判：旁边留着没迁移的
/// 协议 3 库 = needsMigration，别的进程在迁、只剩封存旧库、上次迁移失败都不是 ready），**不开库**：开库会写库
/// （文件头的变更计数等），还原之后若失败本机就不再逐字节原样。没有任何复习库时也不建库。
Future<void> _checkSrsLibraryRestorable(String dbDirectory) async {
  final SrsGen4MigrationStatus st = SrsGen4Migration.status(dbDirectory);
  if (st.state != SrsGenState.ready) {
    throw SrsRestoreBlockedException(st.state.wire);
  }
}

/// 读备份 [archive] 里的复习数据，解到一个新的临时工作目录，回待落库的单元；备份不带复习数据回 null。坏的 / 来自更新
/// 版本的清单在这里抛（[FormatException] / [SrsBackupTooNewException]），此时本机什么都没动。
///
/// [backupDbPath]：已经解出来、迁到当前 schema 的备份主库（合并还原有）；没有时（覆盖还原）需要时从 [dbFile] 另解一份
/// 到工作目录。只有旧形态要读它（profile 名字、老形态的 SRS 表）。
Future<_SrsRestoreUnits?> _prepareSrsRestoreUnits({
  required String zipPath,
  required Archive archive,
  required ArchiveFile dbFile,
  required BackupMeta? meta,
  String? backupDbPath,
  void Function(int deltaBytes)? onBytes,
}) async {
  if (meta?.excludedCategories.contains(BackupCategory.srs.name) ?? false) {
    return null;
  }
  final ArchiveFile? manifestFile = archive.findFile(kSrsBackupManifestEntry);
  final ArchiveFile? p3File = archive.findFile(_srsDbName);
  SrsBackupBundleManifest? manifest;
  if (manifestFile != null) {
    if (manifestFile.size > kSrsBackupManifestMaxBytes) {
      throw const FormatException('srs backup manifest too large');
    }
    manifest = SrsBackupBundleManifest.parse(manifestFile.content as List<int>);
    for (final SrsBackupUnit u in manifest.units) {
      if (archive.findFile(srsBackupStreamEntry(u.n)) == null) {
        throw FormatException(
          'srs backup: ${srsBackupStreamEntry(u.n)} is missing',
        );
      }
    }
  }
  final Directory work = await Directory.systemTemp.createTemp(
    'fushi_srs_restore_',
  );
  final _SrsRestoreUnits out = _SrsRestoreUnits(work, <SrsBackupLandUnit>[]);
  try {
    if (manifest != null) {
      await BackupRestoreService._extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          for (final SrsBackupUnit u in manifest.units)
            MapEntry<String, String>(
              srsBackupStreamEntry(u.n),
              p.join(work.path, '${u.n}.bin'),
            ),
        ],
        onBytes: onBytes,
      );
      for (final SrsBackupUnit u in manifest.units) {
        out.units.add(
          SrsBackupLandUnit(
            profiles: u.profiles,
            file: SrsBackupStreamFile(
              path: p.join(work.path, '${u.n}.bin'),
              unit: u,
            ),
          ),
        );
      }
      return out;
    }
    // 旧形态：要备份主库（profile 名字；老形态的 SRS 表也在里面）。
    String? mainPath = backupDbPath;
    if (mainPath == null) {
      mainPath = p.join(work.path, _dbName);
      await BackupRestoreService._extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          MapEntry<String, String>(dbFile.name, mainPath),
        ],
      );
    }
    if (p3File != null) {
      // 协议 3 的 `srs.db`：解进自己的目录（内核只读它，每个 profile 各拷进自己的 scratch 再备），profile 取「旧库里
      // 有数据的」∩「备份主库里的」。
      final Directory p3Dir = Directory(p.join(work.path, 'p3'));
      await p3Dir.create();
      final String p3Path = p.join(p3Dir.path, kSrsDatabaseFileName);
      await BackupRestoreService._extractEntriesStreaming(
        zipPath: zipPath,
        entries: <MapEntry<String, String>>[
          MapEntry<String, String>(p3File.name, p3Path),
        ],
        onBytes: onBytes,
      );
      final Set<String> withData = (await SrsGen4Migration.legacyProfiles(
        p3Dir.path,
      )).toSet();
      int i = 0;
      for (final SrsBackupProfile bp in await _backupProfilesIn(mainPath)) {
        if (!withData.contains(bp.uid)) continue;
        final Directory scratch = Directory(p.join(work.path, 'p3scratch$i'));
        await scratch.create();
        i++;
        out.units.add(
          SrsBackupLandUnit(
            profiles: <SrsBackupProfile>[bp],
            file: SrsBackupLegacyDbFile(
              path: p3Path,
              scratch: scratch.path,
              backupProfile: bp.uid,
            ),
          ),
        );
      }
    } else if (legacySrsTablesInFile(mainPath)) {
      // 2026-10-23 之前：SRS 表在备份主库里，只有 v1 事件 → JSONL，内核在临时协议 3 库里备好再读入。
      final FushiDatabase src = FushiDatabase.atFile(mainPath);
      try {
        final SrsBackupSource source = SrsBackupSource.database(src);
        int i = 0;
        for (final SrsBackupProfile bp in await source.profilesWithSrsData()) {
          final String jsonl = p.join(work.path, 'events$i.jsonl');
          final Directory scratch = Directory(p.join(work.path, 'scratch$i'));
          await scratch.create();
          i++;
          await srsWriteLegacyEventsJsonl(
            await source.eventsOf(bp.uid),
            File(jsonl),
            noteOfCard: await source.noteOfCard(bp.uid),
          );
          out.units.add(
            SrsBackupLandUnit(
              profiles: <SrsBackupProfile>[bp],
              file: SrsBackupLegacyEventsFile(
                path: jsonl,
                scratch: scratch.path,
                backupProfile: bp.uid,
              ),
            ),
          );
        }
      } finally {
        await src.close();
      }
    }
    if (out.units.isEmpty) {
      await out.dispose();
      return null;
    }
    return out;
  } on Object {
    await out.dispose();
    rethrow;
  }
}

/// 备份主库 [path] 里有 uid 的 profile（按自增 id 排）。
Future<List<SrsBackupProfile>> _backupProfilesIn(String path) async {
  final sqlite.Database db = sqlite.sqlite3.open(
    path,
    mode: sqlite.OpenMode.readOnly,
  );
  try {
    return <SrsBackupProfile>[
      for (final sqlite.Row r in db.select(
        'SELECT name, uid FROM profiles '
        "WHERE uid IS NOT NULL AND uid != '' ORDER BY id",
      ))
        SrsBackupProfile(uid: r['uid'] as String, name: r['name'] as String),
    ];
  } finally {
    db.close();
  }
}

/// 覆盖还原第一步：在暂存目录新建空的新代库，把 [units] 全部落进去（用户选了覆盖 = 对替换复习库的确认）。
/// [finalProfiles] 是主库换好之后会有的 profile（档案来自备份 = 备份里的；否则 = 本机的）：按它们对上 uid / 名字，
/// 对不上的回成待新建的「（备份）」profile（主库换好之后由 [_insertSrsRestoredProfiles] 插）。失败时删掉暂存目录、
/// 原样抛错。
Future<List<Map<String, String>>> _stageSrsRestore({
  required String dbDirectory,
  required _SrsRestoreUnits units,
  required List<SrsLocalProfile> finalProfiles,
}) async {
  final Directory staged = Directory(_srsStagedDir(dbDirectory));
  if (staged.existsSync()) await staged.delete(recursive: true);
  await staged.create();
  final List<SrsLocalProfile> profiles = List<SrsLocalProfile>.of(
    finalProfiles,
  );
  final List<Map<String, String>> pending = <Map<String, String>>[];
  try {
    final SrsCore core = await SrsCore.openInBackground(staged.path);
    try {
      await mergeSrsFromBackup(
        units: units.units,
        localProfiles: () async => profiles,
        localSrs: core,
        confirmed: true,
        freshLibrary: true,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        createProfile: (String name, String uid) async {
          pending.add(<String, String>{'name': name, 'uid': uid});
          profiles.add((id: -1 - pending.length, name: name, uid: uid));
          return null;
        },
      );
    } finally {
      await core.close();
    }
    return pending;
  } on Object {
    if (staged.existsSync()) await staged.delete(recursive: true);
    rethrow;
  }
}

/// 覆盖还原第二步（主库换好之后；崩溃后启动恢复重放，幂等）：本机 `srs4.db`（连同 -wal / -shm，先挪它们：残留的
/// WAL 帧绝不能重放到换进来的库上）改名成回退副本 [rollbackName]（不删），暂存库改名到位。暂存库已不在 = 已换过。
/// 协议 3 的 `srs.db`（封存副本）一概不碰。调用方保证此刻没有任何复习库连接。
Future<void> _swapInStagedSrsLibrary(
  String dbDirectory,
  String rollbackName,
) async {
  final String stagedDir = _srsStagedDir(dbDirectory);
  final String stagedDb = p.join(stagedDir, kSrsGen4DatabaseFileName);
  final String live = SrsStorage.gen4PathIn(dbDirectory);
  if (File(stagedDb).existsSync()) {
    if (File(live).existsSync()) {
      String rollback = p.join(dbDirectory, rollbackName);
      // 同名的回退副本已经在（同一秒里又还原了一次）：另取名，绝不覆盖。
      for (int i = 2; File(rollback).existsSync(); i++) {
        rollback = p.join(dbDirectory, '$rollbackName-$i');
      }
      for (final String suffix in const <String>['-wal', '-shm', '']) {
        final File f = File('$live$suffix');
        if (f.existsSync()) await f.rename('$rollback$suffix');
      }
    }
    for (final String suffix in const <String>['-wal', '-shm', '']) {
      final File f = File('$stagedDb$suffix');
      if (f.existsSync()) await f.rename('$live$suffix');
    }
  }
  final Directory d = Directory(stagedDir);
  if (d.existsSync()) await d.delete(recursive: true);
}

/// 覆盖还原第三步（主库换好、档案层回灌之后；幂等）：插 [_stageSrsRestore] 记下的「（备份）」profile，删掉主库里老形态
/// 的 SRS 表（它们的数据已经落进新代库）。
Future<void> _finishSrsRestoreInMainDb(
  String dbDirectory,
  List<Map<String, String>> pending,
) async {
  final FushiDatabase db = FushiDatabase(dbDirectory);
  try {
    for (final Map<String, String> pr in pending) {
      await insertSrsRestoredProfile(db, name: pr['name']!, uid: pr['uid']!);
    }
    await dropLegacySrsTables(db);
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}

/// sidecar 里覆盖还原的复习计划（`srs` 键）。
Map<String, Object?> _srsGen4PlanJson(
  String rollbackName,
  List<Map<String, String>> pending,
) => <String, Object?>{
  'gen4': true,
  'rollback': rollbackName,
  'profiles': pending,
};

/// 启动恢复：重放 sidecar 的 `srs` 键。新代计划 → 换库 + 主库收尾。协议 3 时代的旧计划（字符串，旧版本还原到一半
/// 崩溃、升级后才重启）→ **不再删 / 换 `srs.db`**（迁移之后它是封存副本；没迁移时它是本机唯一的复习数据），只把没换
/// 进去的暂存文件改名留存、记日志：一张卡、一条记录都不丢，备份里的复习数据可以再还原一次。
Future<void> _recoverSrsRestorePlan(String dbDirectory, Object? plan) async {
  if (plan is Map) {
    final List<Map<String, String>> pending = <Map<String, String>>[
      for (final Map<Object?, Object?> pr
          in ((plan['profiles'] as List?) ?? const <Object?>[]).cast<Map>())
        <String, String>{
          'name': pr['name']! as String,
          'uid': pr['uid']! as String,
        },
    ];
    await _swapInStagedSrsLibrary(dbDirectory, plan['rollback']! as String);
    await _finishSrsRestoreInMainDb(dbDirectory, pending);
    return;
  }
  if (plan is! String) return;
  final File staged = File(BackupRestoreService._srsStagedPath(dbDirectory));
  if (staged.existsSync()) {
    final String kept = '${staged.path}-unapplied';
    await staged.rename(kept);
    debugPrint(
      'srs restore recovery: a protocol 3 restore plan ($plan) was left by an '
      'older version; srs.db is left untouched and the staged file is kept '
      'at $kept',
    );
  }
}
