// 官方「推荐词典 + 本地音频」分发包的导出入口（发布杂务，可重复执行）。
//
// 复用真实的 [BackupService.createBackup]，**不重实现**类别剥离逻辑——导出包里
// 主库要剥掉哪些表、留哪些注册表行，唯一真相源是 backup_service.dart 自己。手工
// 拼 zip 必然和它漂开。
//
// 用 `flutter test` 跑（backup_service 依赖 package:flutter/foundation，纯
// `dart run` 起不来）：
//
//   flutter test tool/pack/export_recommended_pack.dart --no-pub
//
// 通过环境变量注入路径，未设 [_kDbCopyDirEnv] 时整体 skip（不打扰 CI / 全量测试）：
//
//   FUSHI_PACK_DB_COPY_DIR  主库**副本**所在目录（FushiDatabase 在这里开库）
//   FUSHI_PACK_DB_DIRECTORY 真实 support 目录（读 local_audio_*.db + 写进 meta
//                           的 localAudioRoot；导入侧靠它重定基址，必须是真值）
//   FUSHI_PACK_DICT_DIR     dictionaryResources 目录
//   FUSHI_PACK_OUTPUT       输出 zip 路径
//   FUSHI_PACK_APP_VERSION  写进 backup_meta.json 的 appVersion
//
// 为什么 db 和 dbDirectory 分开指：活库正被 app 占用，直接开会触发 drift 迁移，
// 是毁库红线。所以主库开在副本上，而 dbDirectory 仍指真实 support 目录——它只被
// 用来枚举本地音频文件和记录源设备根路径（`_dbPath` 仅在 VACUUM INTO 失败的回退
// 分支才会被读，那条路径会打印 `VACUUM INTO failed`，调用方应据此判失败）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';

const String _kDbCopyDirEnv = 'FUSHI_PACK_DB_COPY_DIR';
const String _kDbDirectoryEnv = 'FUSHI_PACK_DB_DIRECTORY';
const String _kDictDirEnv = 'FUSHI_PACK_DICT_DIR';
const String _kOutputEnv = 'FUSHI_PACK_OUTPUT';
const String _kAppVersionEnv = 'FUSHI_PACK_APP_VERSION';

/// 分发包只带词典和本地音频；其余 8 个类别一律不进包（和 2026-07-15 旧包的
/// `excludedCategories` 一致，避免把个人书库/统计/凭据发出去）。
const Set<BackupCategory> _kPackCategories = <BackupCategory>{
  BackupCategory.dictionary,
  BackupCategory.localAudio,
};

void main() {
  final String? dbCopyDir = Platform.environment[_kDbCopyDirEnv];

  test(
    '导出官方推荐词典 + 本地音频分发包',
    () async {
      final String dbDirectory = _requireEnv(_kDbDirectoryEnv);
      final String dictDirectory = _requireEnv(_kDictDirEnv);
      final String outputPath = _requireEnv(_kOutputEnv);
      final String appVersion = _requireEnv(_kAppVersionEnv);

      final FushiDatabase db = FushiDatabase(dbCopyDir!);
      addTearDown(db.close);

      final BackupService service = BackupService(
        db: db,
        dbDirectory: dbDirectory,
        appVersion: appVersion,
        dictionaryResourceDirectory: dictDirectory,
      );

      final Stopwatch sw = Stopwatch()..start();
      final BackupMeta meta = await service.createBackup(
        outputPath,
        categories: _kPackCategories,
      );
      sw.stop();

      final File output = File(outputPath);
      expect(await output.exists(), isTrue, reason: '导出未落盘：$outputPath');
      final int bytes = await output.length();

      debugPrint('PACK_EXPORT_OK path=$outputPath '
          'bytes=$bytes '
          'schemaVersion=${meta.schemaVersion} '
          'localAudioRoot=${meta.localAudioRoot} '
          'excluded=${meta.excludedCategories.toList()..sort()} '
          'elapsed=${sw.elapsed}');

      // 包不该带上个人内容：这两个计数必须是 0，否则说明类别集合选错了。
      expect(meta.bookCount, 0, reason: '分发包不应携带书/视频记录');
      expect(meta.statsCount, 0, reason: '分发包不应携带统计记录');
      expect(meta.localAudioRoot, dbDirectory,
          reason: 'localAudioRoot 必须是真实 support 目录，导入侧靠它重定基址');
    },
    // 打包 10GB 级素材，默认 30s 超时远远不够。
    timeout: const Timeout(Duration(hours: 4)),
    skip: dbCopyDir == null ? '未设 $_kDbCopyDirEnv：这是发布杂务入口，不在常规测试里跑' : null,
  );
}

String _requireEnv(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('缺少环境变量 $name');
  }
  return value;
}
