import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/lapis_backup_retention.dart';
import 'package:fushi/src/storage/app_paths.dart';

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

/// 「恢复出厂 Lapis」的结果。
enum LapisRestoreFactoryResult {
  /// 已把 Anki 端的 Lapis 卡型推回出厂态（推送前已自动备份）。
  restored,

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
/// 纯逻辑（CSS 组合 / 漂移判定）在 `package:fushi_anki` 的 `lapis_styling.dart`；
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

  /// 只读地取回 Anki 端的卡型定义，供编辑器拿真实基线渲染预览。
  ///
  /// 单独开一个方法而不是把 `_repository` 暴露出去：预览只需要读，不该顺手获得
  /// 写入能力。后端不支持时返回 null（预览退回内置副本）。
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinitionForPreview(
    String modelName,
  ) async {
    if (!_repository.supportsNoteTypeEditing) return null;
    return _repository.readNoteTypeDefinition(modelName);
  }

  /// 手动备份按钮入口：读回当前 Lapis 定义并落盘。模型不存在 / 后端不支持
  /// 返回 null（UI 提示），读写失败照抛。
  Future<LapisBackupOutcome?> backupNow() async {
    final AnkiNoteTypeDefinition? def =
        await _repository.readNoteTypeDefinition(LapisNoteType.modelName);
    if (def == null) return null;
    return _writeBackupFile(def);
  }

  /// 按保留策略清理旧备份：**保留 90 天，且无论如何最少留最近 10 份**
  /// （PR#457 审查 §10-5a，用户拍板方案乙）。返回真正删掉的文件。
  ///
  /// 只在**用户主动触发的备份写盘之后**跑（手动备份 / 应用样式 / 从备份恢复
  /// ——三条路径都会先落一份新备份），不挂任何后台定时器：删除不可逆，不能在
  /// 用户没预期的时机静默批量删。每删一份都 debugPrint 记下文件名，手动备份
  /// 路径还会把份数回给 UI 提示。
  ///
  /// 删不掉（占用/权限）只记日志，不让备份本身失败——新备份已经落地了。
  Future<List<File>> pruneBackups({DateTime? now}) async {
    final List<File> backups = await listBackups(); // 新 → 旧
    final List<File> doomed = planLapisBackupPrune<File>(
      backups,
      timestampOf: (File f) => parseLapisBackupTimestamp(p.basename(f.path)),
      now: now ?? DateTime.now().toUtc(),
    );
    final List<File> deleted = <File>[];
    for (final File f in doomed) {
      final String name = p.basename(f.path);
      try {
        await f.delete();
        deleted.add(f);
        debugPrint('LapisTemplateService.pruneBackups: deleted $name');
      } catch (e) {
        debugPrint('LapisTemplateService.pruneBackups: kept $name ($e)');
      }
    }
    return deleted;
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
    final AnkiNoteTypeDefinition? def =
        await _repository.readNoteTypeDefinition(LapisNoteType.modelName);
    if (def == null) return LapisApplyResult.notFound;

    // 基线取**用户 Anki 里现有的内容**（剥掉我们上一轮的托管区段），不是
    // Hibiki 内置的 vendored 副本。用户反馈「Hibiki 把我的字体改了」的病根就在
    // 这里：我们没写过 font-family，但拿 vendored 全文当基线推送，等于把他那份
    // Lapis（别的版本 / 自己调过字体）整体顶掉。改成叠加之后，字体、版本差异、
    // 他自己的手改全部原样保留。
    final String expected = composeLapisCssOnBase(
      baseCss: stripLapisUserSection(def.css),
      fontScalePercent: settings.lapisFontScalePercent,
      customCss: settings.lapisCustomCss,
    );
    final String expectedBack = composeLapisBackTemplate(
      settings.lapisCustomBlocks,
      baseBack: _currentBackTemplate(def),
    );
    final LapisStylingDecision templateDecision = decideLapisTemplateAction(
      def: def,
      expectedBack: expectedBack,
      lastAppliedSha: settings.lapisAppliedTemplateSha,
    );
    final LapisStylingDecision decision = _mergeLapisDecisions(
      decideLapisStylingAction(
        ankiCss: def.css,
        expectedCss: expected,
        lastAppliedSha: settings.lapisAppliedCssSha,
      ),
      templateDecision,
    );
    if (decision == LapisStylingDecision.upToDate) {
      // 内容已一致但指纹可能还没记（老装置首次升级）：补记。基线指纹同理——
      // Anki 上就是「当前基线 + 当前用户区段」，这个基线已经算迁移过了。
      if (settings.lapisAppliedCssSha == null ||
          settings.lapisMigratedBaselineSha != currentLapisBaselineSha) {
        await _repository.updateSettings((AnkiSettings s) => s.copyWith(
              lapisAppliedCssSha:
                  s.lapisAppliedCssSha ?? lapisCssSha256(expected),
              lapisMigratedBaselineSha: currentLapisBaselineSha,
            ));
      }
      return LapisApplyResult.upToDate;
    }
    if (decision == LapisStylingDecision.foreignEdit && !force) {
      return LapisApplyResult.needsConfirm;
    }
    await _pushCustomization(def, expected, expectedBack);
    return LapisApplyResult.applied;
  }

  /// 恢复出厂 Lapis：把 Anki 端的卡型**整体**推回 Hibiki 内置的 vendored 版本
  /// （样式 + 正反面模板），并清空 Hibiki 侧的全部客制化。
  ///
  /// 与「从备份恢复」的分工：备份恢复是回到**某个历史时刻**，前提是那时候落过
  /// 备份；本方法是回到**出厂**，不依赖任何历史。卡片长歪了又没有可用备份时，
  /// 这是唯一的兜底。
  ///
  /// **刻意不走漂移判定**：用户点这个按钮，本身就是「我知道 Anki 端现在是什么
  /// 样，就是要把它抹掉」的显式声明，再拦一道 foreignEdit 确认没有意义（UI 侧
  /// 已有一次二次确认）。但备份门照走——覆盖前必落一份，写盘失败即中止。
  ///
  /// 清空客制化时把两个指纹**对齐到出厂值**而不是置 null：Anki 端此刻确实就是
  /// 出厂态，指纹如实记录它才能让后续的漂移判定继续认得出「这是我们写的」；
  /// 置 null 会让下次启动的自动迁移把刚恢复好的卡型又当成来历不明。
  Future<LapisRestoreFactoryResult> restoreFactoryDefaults() async {
    if (!_repository.supportsNoteTypeEditing) {
      return LapisRestoreFactoryResult.unsupported;
    }
    final AnkiNoteTypeDefinition? def =
        await _repository.readNoteTypeDefinition(LapisNoteType.modelName);
    if (def == null) return LapisRestoreFactoryResult.notFound;
    await _writeBackupFile(def);

    final String css = LapisNoteType.template.css;
    final bool stylingOk =
        await _repository.updateNoteTypeStyling(def.name, css);
    if (!stylingOk) throw StateError('Backend rejected styling update');

    final bool templatesOk = await _repository.updateNoteTypeTemplates(
      def.name,
      <AnkiCardTemplate>[
        const AnkiCardTemplate(
          name: LapisNoteType.cardName,
          front: LapisNoteType.front,
          back: LapisNoteType.back,
        ),
      ],
    );
    if (!templatesOk) throw StateError('Backend rejected card template update');

    await _repository.updateSettings((AnkiSettings s) => s.copyWith(
          lapisFontScalePercent: 100,
          lapisCustomCss: '',
          lapisCustomBlocks: const <LapisCustomBlock>[],
          lapisAppliedCssSha: lapisCssSha256(css),
          lapisAppliedTemplateSha:
              lapisCssSha256(normalizeCssForCompare(LapisNoteType.back)),
          lapisMigratedBaselineSha: currentLapisBaselineSha,
        ));
    return LapisRestoreFactoryResult.restored;
  }

  /// 样式与模板两份判定合成一份：**取更保守的那个**。
  ///
  /// 任一侧疑似手改 → 整体 foreignEdit（要用户确认），因为一次 Apply 会同时写
  /// 两边；只有两边都已是最新才算 upToDate。
  static LapisStylingDecision _mergeLapisDecisions(
    LapisStylingDecision css,
    LapisStylingDecision template,
  ) {
    if (css == LapisStylingDecision.foreignEdit ||
        template == LapisStylingDecision.foreignEdit) {
      return LapisStylingDecision.foreignEdit;
    }
    if (css == LapisStylingDecision.upToDate &&
        template == LapisStylingDecision.upToDate) {
      return LapisStylingDecision.upToDate;
    }
    return LapisStylingDecision.safeUpdate;
  }

  /// 启动自动迁移：**只有 Hibiki 出厂基线真的变了**才自动备份并推送新
  /// styling。手改内容（foreignEdit）绝不自动覆盖。每进程最多跑一次；Anki
  /// 未运行时静默跳过（常态，不是错误，下次启动再试）。
  ///
  /// 基线闸门（PR#457 审查 §10-3，用户拍板方案甲）：改字号 / 自定义 CSS 却
  /// 没点「应用样式到 Anki」时，这里**什么都不做**——Apply 是用户内容写进
  /// Anki 的唯一闸门。判据见 [shouldAutoMigrateLapisBaseline]。
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
    // 基线取用户自己的（同 applyCustomization）：自动路径更不该拿 vendored
    // 全文去顶用户的 Lapis。
    final String expected = composeLapisCssOnBase(
      baseCss: stripLapisUserSection(def.css),
      fontScalePercent: settings.lapisFontScalePercent,
      customCss: settings.lapisCustomCss,
    );
    final String baselineSha = currentLapisBaselineSha;
    if (!shouldAutoMigrateLapisBaseline(
      migratedBaselineSha: settings.lapisMigratedBaselineSha,
      ankiCss: def.css,
    )) {
      // 基线没变：用户没点 Apply 就不动 Anki。顺手把基线指纹补记上（老装置
      // 首次升级上来是 null），之后连判都不用判。
      if (settings.lapisMigratedBaselineSha != baselineSha) {
        await _repository.updateSettings((AnkiSettings s) =>
            s.copyWith(lapisMigratedBaselineSha: baselineSha));
      }
      debugPrint('LapisTemplateService.autoMigrate: baseline unchanged, '
          'skipped (Apply is the only write gate)');
      return;
    }
    final LapisStylingDecision decision = decideLapisStylingAction(
      ankiCss: def.css,
      expectedCss: expected,
      lastAppliedSha: settings.lapisAppliedCssSha,
    );
    switch (decision) {
      case LapisStylingDecision.upToDate:
        await _repository.updateSettings((AnkiSettings s) => s.copyWith(
              lapisAppliedCssSha:
                  s.lapisAppliedCssSha ?? lapisCssSha256(expected),
              lapisMigratedBaselineSha: baselineSha,
            ));
      case LapisStylingDecision.safeUpdate:
        // **不再自动写 Anki。** 这条路径原本的意义是「Hibiki 出厂基线升级了，
        // 把新基线同步过去」——而基线现在取自用户自己的 Lapis，我们根本不再
        // 拥有基线，这个动作失去了前提。它同时是唯一一条「用户没点任何按钮就
        // 改他 Anki」的路径（用户反馈字体被改，这里是最大嫌疑）。保留判定只为
        // 记指纹，写入统一收敛到用户显式点「应用样式到 Anki」那一个闸门。
        await _repository.updateSettings((AnkiSettings s) => s.copyWith(
              lapisMigratedBaselineSha: baselineSha,
            ));
        debugPrint('LapisTemplateService.autoMigrate: write skipped by design '
            '(Apply is the only write gate)');
      case LapisStylingDecision.foreignEdit:
        // 用户手改过：不动，也不记基线（下次启动还要再判）。显式「应用」
        // 流程里有确认弹窗兜这条路。
        break;
    }
  }

  /// 从备份恢复（styling + 卡模板）。恢复前先快照当前状态。
  ///
  /// 恢复后把 Hibiki 侧客制化状态与备份**对齐**，否则下次启动的自动迁移会把
  /// 刚恢复的内容又覆写回去（根因：期望态与 Anki 态不一致 + 指纹仍认识
  /// Anki 态 = safeUpdate）：
  /// - 备份含用户区段 → 正文用 [splitLapisUserSectionBody] **拆回**「字号
  ///   百分比 + 自由 CSS」再回填，期望态 == 恢复态。拆分而不是整段塞进
  ///   `lapisCustomCss`：整段塞会让旧缩放块永远排在新缩放块之后并盖住它，
  ///   恢复之后字号选择器就成了死控件（PR#457 审查 §10-2）。
  /// - 备份无用户区段 → 清空客制化并**清掉指纹**：若恢复的是出厂基线，漂移
  ///   判定本就允许升级；若是手改快照，判定变 foreignEdit，自动迁移不再动它。
  ///
  /// 写入顺序 styling → 对齐 settings → 卡模板：三步任意一步失败都抛给调用方
  /// 提示，**不静默降级成「恢复成功」**。卡模板失败时 styling 与 settings 已一致
  /// （非半态），只是卡模板仍是旧的，用户可重试恢复。
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
    // styling 一旦落地，Hibiki 侧客制化状态必须**立刻**对齐：settings 里
    // lapisCustomCss / lapisAppliedCssSha 描述的就是 styling，晚一步对齐就有一段
    // 「Anki 是恢复态、Hibiki 期望态还是旧的」窗口，下次启动的漂移判定读到过期
    // 期望态。所以对齐排在卡模板写入之前——卡模板失败不该连累 styling 状态。
    final String? body = extractLapisUserSectionBody(def.css);
    final LapisUserSectionSplit? split =
        body == null ? null : splitLapisUserSectionBody(body);
    await _repository.updateSettings((AnkiSettings s) => s.copyWith(
          lapisFontScalePercent: split?.fontScalePercent ?? 100,
          lapisCustomCss: split?.customCss ?? '',
          lapisAppliedCssSha: body != null ? lapisCssSha256(def.css) : null,
          clearLapisAppliedCssSha: body == null,
          // 恢复是用户对「Anki 里该是什么」的显式决定，启动自动迁移不得把它
          // 撤销：记下当前基线 = 这个基线已处理过，只有**将来**基线再变才推。
          lapisMigratedBaselineSha: currentLapisBaselineSha,
        ));
    // 卡模板（settings 不持有其状态）单独写。返回 false = 后端拒写，必须上抛
    // 让 UI 报「恢复失败」——吞掉它会把「只恢复了 styling」谎报成完整恢复。
    if (def.templates.isNotEmpty) {
      final bool templatesOk =
          await _repository.updateNoteTypeTemplates(def.name, def.templates);
      if (!templatesOk) {
        throw StateError('Backend rejected card template update');
      }
      // 恢复出来的模板同样是 Hibiki 亲手写进去的，记下指纹——否则下次 Apply 会
      // 把自己刚写的内容当成「疑似手改」，凭空多弹一次确认框。
      final AnkiCardTemplate? card = def.templates
          .where((AnkiCardTemplate t) => t.name == LapisNoteType.cardName)
          .firstOrNull;
      await _repository.updateSettings(
        (AnkiSettings s) => s.copyWith(
          lapisAppliedTemplateSha: card == null
              ? null
              : lapisCssSha256(normalizeCssForCompare(card.back)),
          clearLapisAppliedTemplateSha: card == null,
        ),
      );
    }
  }

  /// 显式 Apply 的写入通道：备份 → styling → 卡模板，**每步成功就立刻记自己的
  /// 指纹**。
  ///
  /// 两个指纹分开记而不是等两步都成功再一起记：任一步失败时，已落地的那步的
  /// Hibiki 侧状态与 Anki 端保持一致，重试只会重做真正没成功的那一步。合并记录
  /// 反而会让重试把已经正确的一边再判成「要更新」。
  ///
  /// 先 styling 后模板：模板写入是风险更高的一步，放在后面能让它失败时前一步
  /// 处于已知一致状态；失败照抛给 UI，绝不静默降级成「应用成功」。
  Future<void> _pushCustomization(
    AnkiNoteTypeDefinition def,
    String css,
    String back,
  ) async {
    await _writeBackupFile(def);
    final bool stylingOk =
        await _repository.updateNoteTypeStyling(def.name, css);
    if (!stylingOk) throw StateError('Backend rejected styling update');
    await _repository.updateSettings((AnkiSettings s) => s.copyWith(
          lapisAppliedCssSha: lapisCssSha256(css),
          lapisMigratedBaselineSha: currentLapisBaselineSha,
        ));

    // 只换 Lapis 那张卡的**背面**；正面与其它卡模板逐字节原样带回。正面我们
    // 从不写——区域只插在背面，把 vendored 正面推过去等于又一次「用内置副本
    // 顶掉用户的东西」。
    final bool templatesOk = await _repository.updateNoteTypeTemplates(
      def.name,
      lapisTemplatesWithBack(def, back),
    );
    if (!templatesOk) throw StateError('Backend rejected card template update');
    await _repository.updateSettings((AnkiSettings s) => s.copyWith(
          lapisAppliedTemplateSha: lapisCssSha256(normalizeCssForCompare(back)),
        ));
  }

  /// Anki 端当前的背面模板；取不到就退回 vendored（只在卡模板缺失时发生，那种
  /// 情况漂移判定已经判 foreignEdit）。
  String _currentBackTemplate(AnkiNoteTypeDefinition def) =>
      lapisCardTemplateOf(def)?.back ?? LapisNoteType.back;

  Future<LapisBackupOutcome> _writeBackupFile(
      AnkiNoteTypeDefinition def) async {
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
    // 保留策略只在这里生效：新备份已经落地（备份门已过），再按 90 天 / 最少
    // 10 份清理。顺序不能反——先删后写会在写盘失败时既没新备份也少了旧备份。
    return LapisBackupOutcome(file: file, pruned: await pruneBackups());
  }
}

/// 一次备份写盘的结果：新落地的备份文件 + 本次按保留策略清理掉的旧备份。
class LapisBackupOutcome {
  const LapisBackupOutcome({required this.file, required this.pruned});

  /// 新写入的备份文件。
  final File file;

  /// 本次真正删掉的旧备份（可能为空）。UI 据此告诉用户清理了几份。
  final List<File> pruned;

  int get prunedCount => pruned.length;
}
