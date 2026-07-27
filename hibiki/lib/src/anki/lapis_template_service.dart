import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

/// 显式「应用样式到 Anki」的结果（设置页据此提示/弹确认）。
enum LapisApplyResult {
  /// 已推送（推送前已自动备份）。
  applied,

  /// 已是最新，无需推送。
  upToDate,

  /// Anki 端模板与 Hibiki 已知产物不一致（疑似手改），需要用户确认后带
  /// `force: true` 重试。
  needsConfirm,

  /// Anki 里没有 Lapis note type（先走「创建 Lapis 卡组」）。
  notFound,

  /// 当前后端不支持模板读写（AnkiDroid / AnkiMobile）。
  unsupported,
}

/// Lapis 模板的备份 / 恢复 / 客制化应用 / 启动自动迁移。
///
/// 硬规则：**任何写模板的操作都先落一份带时间戳的 JSON 备份**（写盘失败即
/// 中止推送）——备份是门，不是装饰。备份落在
/// `<supportRoot>/backups/lapis/lapis-<UTC时间戳>.json`。
///
/// 纯逻辑（CSS 组合 / 漂移判定）在 `package:hibiki_anki` 的 `lapis_styling.dart`；
/// 本类只做编排与落盘。
class LapisTemplateService {
  LapisTemplateService(this._repository);

  final BaseAnkiRepository _repository;

  /// 启动自动迁移的会话级闸门：HomePage 可能重建，迁移每次进程只跑一次。
  static bool _autoMigrateRanThisSession = false;

  /// 测试用：重置会话级闸门。
  @visibleForTesting
  static void resetAutoMigrateSessionGate() =>
      _autoMigrateRanThisSession = false;

  Future<Directory> backupDirectory() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory dir = Directory(p.join(support.path, 'backups', 'lapis'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 手动备份按钮入口：读回当前 Lapis 定义并落盘。模型不存在 / 后端不支持
  /// 返回 null（UI 提示），读写失败照抛。
  Future<File?> backupNow() async {
    final AnkiNoteTypeDefinition? def =
        await _repository.readNoteTypeDefinition(LapisNoteType.modelName);
    if (def == null) return null;
    return _writeBackupFile(def);
  }

  /// 现有备份，新的在前（文件名含 ISO 时间戳，字典序即时间序）。
  Future<List<File>> listBackups() async {
    final Directory dir = await backupDirectory();
    final List<File> files = (await dir.list().toList())
        .whereType<File>()
        .where((File f) => p.basename(f.path).startsWith('lapis-'))
        .where((File f) => f.path.endsWith('.json'))
        .toList()
      ..sort((File a, File b) => b.path.compareTo(a.path));
    return files;
  }

  /// 解析一份备份文件；格式坏了返回 null（UI 提示，不抛）。
  Future<AnkiNoteTypeDefinition?> readBackup(File file) async {
    try {
      final Map<String, dynamic> json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AnkiNoteTypeDefinition.fromJson(
          json['noteType'] as Map<String, dynamic>);
    } catch (e, stack) {
      debugPrint('LapisTemplateService.readBackup: $e\n$stack');
      return null;
    }
  }

  /// 显式应用客制化样式（设置页「应用样式到 Anki」）。
  ///
  /// [force] = 用户已在确认弹窗里同意覆盖手改内容。
  Future<LapisApplyResult> applyCustomization({bool force = false}) async {
    if (!_repository.supportsNoteTypeEditing) {
      return LapisApplyResult.unsupported;
    }
    final AnkiSettings settings = await _repository.loadSettings();
    final String expected = composeLapisCss(
      fontScalePercent: settings.lapisFontScalePercent,
      customCss: settings.lapisCustomCss,
    );
    final AnkiNoteTypeDefinition? def =
        await _repository.readNoteTypeDefinition(LapisNoteType.modelName);
    if (def == null) return LapisApplyResult.notFound;
    final LapisStylingDecision decision = decideLapisStylingAction(
      ankiCss: def.css,
      expectedCss: expected,
      lastAppliedSha: settings.lapisAppliedCssSha,
    );
    if (decision == LapisStylingDecision.upToDate) {
      // 内容已一致但指纹可能还没记（老装置首次升级）：补记。
      if (settings.lapisAppliedCssSha == null) {
        await _repository.updateSettings((AnkiSettings s) =>
            s.copyWith(lapisAppliedCssSha: lapisCssSha256(expected)));
      }
      return LapisApplyResult.upToDate;
    }
    if (decision == LapisStylingDecision.foreignEdit && !force) {
      return LapisApplyResult.needsConfirm;
    }
    await _pushStyling(def, expected);
    return LapisApplyResult.applied;
  }

  /// 启动自动迁移：Hibiki 基线或客制化变了，且 Anki 端还是 Hibiki 已知产物
  /// （上次推送指纹 / 出厂基线）时，自动备份后推送新 styling。手改内容
  /// （foreignEdit）绝不自动覆盖。每进程最多跑一次；Anki 未运行时静默跳过
  /// （常态，不是错误，下次启动再试）。
  Future<void> maybeAutoMigrateOnStartup() async {
    if (_autoMigrateRanThisSession) return;
    _autoMigrateRanThisSession = true;
    if (!_repository.supportsNoteTypeEditing) return;
    final AnkiNoteTypeDefinition? def;
    try {
      def = await _repository.readNoteTypeDefinition(LapisNoteType.modelName);
    } catch (e) {
      debugPrint(
          'LapisTemplateService.autoMigrate: Anki unreachable, skipped: $e');
      return;
    }
    if (def == null) return;
    final AnkiSettings settings = await _repository.loadSettings();
    final String expected = composeLapisCss(
      fontScalePercent: settings.lapisFontScalePercent,
      customCss: settings.lapisCustomCss,
    );
    final LapisStylingDecision decision = decideLapisStylingAction(
      ankiCss: def.css,
      expectedCss: expected,
      lastAppliedSha: settings.lapisAppliedCssSha,
    );
    switch (decision) {
      case LapisStylingDecision.upToDate:
        if (settings.lapisAppliedCssSha == null) {
          await _repository.updateSettings((AnkiSettings s) =>
              s.copyWith(lapisAppliedCssSha: lapisCssSha256(expected)));
        }
      case LapisStylingDecision.safeUpdate:
        await _pushStyling(def, expected);
        debugPrint('LapisTemplateService.autoMigrate: styling migrated');
      case LapisStylingDecision.foreignEdit:
        // 用户手改过：不动。显式「应用」流程里有确认弹窗兜这条路。
        break;
    }
  }

  /// 从备份恢复（styling + 卡模板）。恢复前先快照当前状态。
  ///
  /// 恢复后把 Hibiki 侧客制化状态与备份**对齐**，否则下次启动的自动迁移会把
  /// 刚恢复的内容又覆写回去（根因：期望态与 Anki 态不一致 + 指纹仍认识
  /// Anki 态 = safeUpdate）：
  /// - 备份含用户区段 → 区段正文回填 `lapisCustomCss`（字号缩放已含在正文
  ///   里，`lapisFontScalePercent` 归 100），期望态 == 恢复态。
  /// - 备份无用户区段 → 清空客制化并**清掉指纹**：若恢复的是出厂基线，漂移
  ///   判定本就允许升级；若是手改快照，判定变 foreignEdit，自动迁移不再动它。
  Future<void> restoreBackup(File file) async {
    final AnkiNoteTypeDefinition? def = await readBackup(file);
    if (def == null) {
      throw const FormatException('Malformed Lapis backup file');
    }
    final AnkiNoteTypeDefinition? current =
        await _repository.readNoteTypeDefinition(def.name);
    if (current == null) {
      throw StateError('Lapis note type not found in Anki');
    }
    await _writeBackupFile(current);
    final bool stylingOk =
        await _repository.updateNoteTypeStyling(def.name, def.css);
    if (!stylingOk) throw StateError('Backend rejected styling update');
    if (def.templates.isNotEmpty) {
      await _repository.updateNoteTypeTemplates(def.name, def.templates);
    }
    final String? body = extractLapisUserSectionBody(def.css);
    await _repository.updateSettings((AnkiSettings s) => s.copyWith(
          lapisFontScalePercent: 100,
          lapisCustomCss: body ?? '',
          lapisAppliedCssSha: body != null ? lapisCssSha256(def.css) : null,
          clearLapisAppliedCssSha: body == null,
        ));
  }

  /// 备份 [def] → 推送 [css] → 记指纹。写模板的唯一通道（备份门在这里）。
  Future<void> _pushStyling(AnkiNoteTypeDefinition def, String css) async {
    await _writeBackupFile(def);
    final bool ok = await _repository.updateNoteTypeStyling(def.name, css);
    if (!ok) throw StateError('Backend rejected styling update');
    await _repository.updateSettings((AnkiSettings s) =>
        s.copyWith(lapisAppliedCssSha: lapisCssSha256(css)));
  }

  Future<File> _writeBackupFile(AnkiNoteTypeDefinition def) async {
    final Directory dir = await backupDirectory();
    // Windows 文件名不允许冒号；替换后仍保持字典序 == 时间序。
    final String stamp =
        DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final File file = File(p.join(dir.path, 'lapis-$stamp.json'));
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'noteType': def.toJson(),
    }));
    return file;
  }
}
