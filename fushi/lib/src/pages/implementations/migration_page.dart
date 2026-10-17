import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_readonly.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// 「迁移到 Fushi」页（改名迁移计划 P1-3）。
///
/// 三态引导（依据 Fushi 是否已安装）：未装 → 下载；已装 → 开始迁移；
/// 全部批次导出完成 → 打开 Fushi + 本应用进入只读态（P1-4 标志位落
/// [kMigrationReadonlyPrefKey]，注销 PROCESS_TEXT 系统入口；重传通道保留——
/// 本页随时可「重新导出」）。
///
/// 仅 Android 挂入口（跨包名迁移只存在于 Android；桌面端数据可直接搬）。
class MigrationPage extends StatefulWidget {
  const MigrationPage({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MigrationPage> createState() => _MigrationPageState();
}

/// Fushi 发布页（下载引导用；与更新检查同仓）。
const String kFushiReleasesUrl =
    'https://github.com/hajisensai/fushi/releases';

enum _TargetState { checking, missing, installed }

class _MigrationPageState extends State<MigrationPage> {
  static const MigrationTargetChannel _channel = MigrationTargetChannel();

  _TargetState _target = _TargetState.checking;
  bool _running = false;
  bool _includeLocalAudio = false;
  bool _allDone = false;
  String? _error;

  /// 已完成批次名 → 显示为勾。
  final Set<String> _doneBatches = <String>{};
  String? _currentBatch;

  @override
  void initState() {
    super.initState();
    _refreshTarget();
    _allDone =
        widget.appModel.prefsRepo.getPref(kMigrationReadonlyPrefKey) == true;
  }

  Future<void> _refreshTarget() async {
    final bool installed = await _channel.isFushiInstalled();
    if (!mounted) return;
    setState(() {
      _target = installed ? _TargetState.installed : _TargetState.missing;
    });
  }

  String _batchLabel(MigrationBatch batch) => switch (batch) {
        MigrationBatch.core => t.migration_batch_core_label,
        MigrationBatch.dictionaries => t.backup_category_dictionary,
        MigrationBatch.books => t.backup_category_books,
        MigrationBatch.audiobooks => t.backup_category_audiobooks,
        MigrationBatch.fonts => t.backup_category_fonts,
        MigrationBatch.localAudio => t.backup_category_local_audio,
      };

  Future<Directory> _transferDir() async {
    final String documents =
        await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_DOCUMENTS);
    // 计划 P1-1 定值：不在 /Android/data 下，卸载老版不会被系统清掉。
    return Directory(p.join(documents, 'Hibiki', 'migration'));
  }

  Future<void> _run({required bool fresh}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
      if (fresh) {
        _doneBatches.clear();
        _allDone = false;
      }
    });
    final AppModel appModel = widget.appModel;
    try {
      final Directory transferDir = await _transferDir();
      if (fresh && transferDir.existsSync()) {
        transferDir.deleteSync(recursive: true);
      }
      final BackupService service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
        booksRootDirectory: p.join(appModel.appDirectory.path, 'fushi_books'),
        audiobooksRootDirectory:
            p.join(appModel.appDirectory.path, 'audiobooks'),
        fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
        gameCoversRootDirectory:
            p.join(appModel.appDirectory.path, 'game_covers'),
      );
      final MigrationExporter exporter = MigrationExporter(
        backupService: service,
        transferDir: transferDir,
        sourcePackage: kHibikiPackageName,
        sourceAppVersion: appModel.packageInfo.version,
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );
      final MigrationPlan plan =
          exporter.planBatches(includeLocalAudio: _includeLocalAudio);
      for (final MigrationBatch batch in plan.batches) {
        if (!mounted) return;
        setState(() => _currentBatch = batch.name);
        await exporter.exportBatch(batch);
        if (!mounted) return;
        setState(() => _doneBatches.add(batch.name));
      }
      // 全批完成：置只读标志（每次启动生效）+ 注销系统取词入口（P1-4）。
      await appModel.prefsRepo.setPref(kMigrationReadonlyPrefKey, true);
      await _channel.setProcessTextEnabled(false);
      if (!mounted) return;
      setState(() => _allDone = true);
      // 前台拉起 Fushi 开始导入（用户点按钮触发的流程末端，属前台启动）。
      await _channel.launchFushi();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _currentBatch = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final List<MigrationBatch> batches = <MigrationBatch>[
      MigrationBatch.core,
      MigrationBatch.dictionaries,
      MigrationBatch.books,
      MigrationBatch.audiobooks,
      MigrationBatch.fonts,
      if (_includeLocalAudio) MigrationBatch.localAudio,
    ];
    final List<Widget> sections = <Widget>[
      Text(
        t.migration_intro,
        style: type.bodyLarge.copyWith(color: colors.onSurfaceVariant),
      ),
      // 已导出完成：本应用只读，tonal 色块常驻提示。
      if (_allDone)
        _MigrationToneCard(
          icon: FushiIcons.lock,
          tone: FushiCardTone.tertiary,
          message: t.migration_readonly_note,
        ),
      if (_target == _TargetState.checking)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: FushiLoadingView(compact: true),
        ),
      if (_target == _TargetState.missing)
        _MigrationToneCard(
          icon: FushiIcons.download,
          tone: FushiCardTone.secondary,
          message: t.migration_target_missing,
          actions: <Widget>[
            FushiTextButton(
              onPressed: _refreshTarget,
              child: Text(t.retry),
            ),
            FushiFilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(kFushiReleasesUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const FushiIcon(FushiIcons.openInNew),
              label: Text(t.migration_download_fushi),
            ),
          ],
        ),
      if (_target == _TargetState.installed) ...<Widget>[
        FushiCard(
          padding: EdgeInsets.zero,
          child: AdaptiveSettingsSwitchRow(
            title: t.migration_include_local_audio,
            value: _includeLocalAudio,
            onChanged: _running
                ? null
                : (bool v) => setState(() => _includeLocalAudio = v),
          ),
        ),
        // 批次进度：一组分段卡片，每行行首是状态形状（完成 = primary cookie
        // 勾、进行中 = 进度圈、未开始 = 中性圆）。
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < batches.length; i++)
              FushiGroupedListItem(
                index: i,
                count: batches.length,
                selected: _currentBatch == batches[i].name,
                child: FushiListItem(
                  leading: _batchLeading(batches[i]),
                  title: Text(_batchLabel(batches[i])),
                ),
              ),
          ],
        ),
        if (_error != null)
          FushiInlineNotice(
            message: t.migration_export_failed(error: _error!),
            severity: FushiNoticeSeverity.error,
          ),
        if (_allDone)
          _MigrationToneCard(
            icon: FushiIcons.success,
            tone: FushiCardTone.primary,
            message: t.migration_export_done,
            actions: <Widget>[
              FushiTextButton(
                onPressed: _running ? null : () => _run(fresh: true),
                child: Text(t.migration_reexport),
              ),
              FushiFilledButton.icon(
                onPressed: _running ? null : () => _channel.launchFushi(),
                icon: const FushiIcon(FushiIcons.openInNew),
                label: Text(t.migration_open_fushi),
              ),
            ],
          )
        else
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FushiFilledButton.icon(
              size: FushiButtonSize.m,
              onPressed: _running ? null : () => _run(fresh: false),
              icon: _running
                  ? const SizedBox.square(
                      dimension: 18,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FushiIcon(FushiIcons.moveFile),
              label: _running
                  ? Text(
                      t.migration_batch_running(batch: _currentBatch ?? ''),
                    )
                  : Text(t.migration_start),
            ),
          ),
      ],
    ];
    return FushiPageScaffold(
      title: t.migration_settings_entry,
      body: FushiEntranceScope(
        // Builder：在页头脚手架之内取 MediaQuery 顶部让位，正文滚到浮动页头底下。
        child: Builder(
          builder: (BuildContext context) => ListView(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            children: <Widget>[
              for (int i = 0; i < sections.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i == sections.length - 1 ? 0 : tokens.spacing.card,
                  ),
                  child: FushiStaggeredEntrance(index: i, child: sections[i]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _batchLeading(MigrationBatch batch) {
    final FushiSpringSpec spring = context.fushiMotion.spatialFast;
    final Widget leading;
    if (_doneBatches.contains(batch.name)) {
      leading = const FushiListLeadingIcon(
        FushiIcons.success,
        key: ValueKey<String>('done'),
        shape: FushiLeadingShape.cookie,
        tone: FushiCardTone.primary,
      );
    } else if (_currentBatch == batch.name) {
      leading = const SizedBox.square(
        key: ValueKey<String>('running'),
        dimension: 40,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: FushiCircularProgressIndicator(strokeWidth: 3),
        ),
      );
    } else {
      leading = const FushiListLeadingIcon(
        FushiIcons.pending,
        key: ValueKey<String>('pending'),
        tone: FushiCardTone.neutral,
      );
    }
    return AnimatedSwitcher(
      duration: spring.duration,
      switchInCurve: spring.curve,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          ScaleTransition(scale: animation, child: child),
      child: leading,
    );
  }
}

/// 迁移页的状态色块卡：M3E 饱和 container 色块 + 行首图标 + 说明，可带一排动作
/// （右对齐，主动作在最右）。
class _MigrationToneCard extends StatelessWidget {
  const _MigrationToneCard({
    required this.icon,
    required this.tone,
    required this.message,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final FushiCardTone tone;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiIcon(icon),
              SizedBox(width: tokens.spacing.card),
              Expanded(
                child: Text(
                  message,
                  style: context.fushiType.bodyLarge.copyWith(
                    color: fushiCardToneColors(context, tone)?.onContainer,
                  ),
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}
