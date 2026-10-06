import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/sync/external_reader_import/external_reader_import_service.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/misc/screen_wakelock.dart';

/// 「从 Hoshi Reader 导入」页：选 `.hoshi` 书库备份 → 扫描并预览 → 逐本导入书、
/// 阅读位置与统计 → 结果报告。落库逻辑全在 [ExternalReaderImportService]，
/// 本页只管选文件、展示与进度；导入结束自己失效书库相关 provider。
class ExternalReaderImportPage extends ConsumerStatefulWidget {
  const ExternalReaderImportPage({super.key, required this.appModel});

  final AppModel appModel;

  /// 测试钩子：替换系统文件选择器（原生选择器不在 Flutter 焦点树里，离屏集成测试
  /// 的合成按键驱动不了它）。null = 走真选择器。
  @visibleForTesting
  static Future<String?> Function()? debugPickBackupPath;

  @override
  ConsumerState<ExternalReaderImportPage> createState() =>
      _ExternalReaderImportPageState();
}

class _ExternalReaderImportPageState
    extends ConsumerState<ExternalReaderImportPage> {
  late final ExternalReaderImportService _service = ExternalReaderImportService(
    db: widget.appModel.database,
  );

  ExternalReaderBackup? _backup;
  ExternalReaderImportPreview? _preview;
  ExternalReaderImportReport? _report;
  bool _scanning = false;
  bool _running = false;
  bool _cancelRequested = false;
  String? _error;
  String? _progressLabel;
  double? _progressValue;

  @override
  void dispose() {
    // 扫描过却没导入就离开：移动端缓存里那份备份拷贝同样要清。
    if (!_running &&
        _backup != null &&
        (Platform.isAndroid || Platform.isIOS)) {
      unawaited(FilePicker.platform.clearTemporaryFiles());
    }
    super.dispose();
  }

  Future<void> _pickBackup() async {
    if (_scanning || _running) return;
    final Future<String?> Function()? debugPick =
        ExternalReaderImportPage.debugPickBackupPath;
    final String? path = debugPick != null
        ? await debugPick()
        : await pickSystemFilePath(
            context: context,
            allowedExtensions: const <String>{'hoshi', 'zip'},
          );
    if (path == null || !mounted) return;
    setState(() {
      _scanning = true;
      _error = null;
      _backup = null;
      _preview = null;
      _report = null;
    });
    try {
      final ExternalReaderBackup backup = await scanExternalReaderBackup(path);
      final ExternalReaderImportPreview preview = await _service.preview(
        backup,
      );
      if (!mounted) return;
      setState(() {
        _backup = backup;
        _preview = preview;
      });
    } on ExternalReaderBackupFormatException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${t.hoshi_import_scan_invalid}\n${e.message}');
    } catch (e, st) {
      ErrorLogService.instance.log('ExternalReaderImportPage.scan', e, st);
      if (!mounted) return;
      setState(() => _error = '${t.hoshi_import_scan_invalid}\n$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _runImport() async {
    final ExternalReaderBackup? backup = _backup;
    if (backup == null || _running) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _error = null;
      _progressValue = 0;
      _progressLabel = null;
    });
    await setScreenWakelock(enable: true, source: 'external reader import');
    try {
      final ExternalReaderImportReport report = await _service.run(
        backup,
        onProgress: (int done, int total, String title) {
          if (!mounted) return;
          setState(() {
            _progressValue = total == 0 ? null : done / total;
            _progressLabel = title.isEmpty
                ? null
                : t.hoshi_import_book_running(
                    current: done + 1,
                    total: total,
                    title: title,
                  );
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _backup = null;
        _preview = null;
      });
    } catch (e, st) {
      ErrorLogService.instance.log('ExternalReaderImportPage.run', e, st);
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      await setScreenWakelock(enable: false, source: 'external reader import');
      // 移动端系统选择器把整份备份拷进了缓存：用完即清，免得几个 GB 常驻。
      if (Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.clearTemporaryFiles();
      }
      _refreshLibrary();
      if (mounted) {
        setState(() {
          _running = false;
          _progressLabel = null;
          _progressValue = null;
        });
      }
    }
  }

  /// 书集合的新增由 [fushiBooksProvider] 自己订阅；阅读位置 / 最近阅读不在那条
  /// 订阅里，导入后显式失效一次。
  void _refreshLibrary() {
    if (!mounted) return;
    ref.invalidate(fushiBooksProvider);
    ref.invalidate(srtBooksProvider);
    ref.invalidate(bookLastReadAtProvider);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> sections = <Widget>[
      // 起点卡：怎么拿到 .hoshi 备份 + 选文件（tonal，扫描 / 导入中禁用）。
      FushiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const FushiListLeadingIcon(
                  FushiIcons.importFile,
                  shape: FushiLeadingShape.cookie,
                  tone: FushiCardTone.primary,
                ),
                SizedBox(width: tokens.spacing.card),
                Expanded(
                  child: Text(
                    t.hoshi_import_how_to,
                    style: context.fushiType.bodyLarge,
                  ),
                ),
              ],
            ),
            SizedBox(height: tokens.spacing.card),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FushiFilledButton.tonalIcon(
                onPressed: _scanning || _running ? null : _pickBackup,
                icon: const FushiIcon(FushiIcons.folderOpen),
                label: Text(t.hoshi_import_file_pick),
              ),
            ),
          ],
        ),
      ),
      if (_scanning) FushiLoadingView(message: t.hoshi_import_scan_running),
      // 错误走共享提示块（中性底 + 错误色图标），不再是裸红字。
      if (_error != null)
        FushiInlineNotice(
          severity: FushiNoticeSeverity.error,
          message: _error!,
        ),
      if (_preview != null) _buildPreview(theme, _preview!),
      if (_report != null) _buildReport(theme, _report!),
    ];
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _running) setState(() => _cancelRequested = true);
      },
      child: FushiPageScaffold(
        title: t.hoshi_import_entry,
        body: FushiEntranceScope(
          // 扫描结果 / 导入报告落地时重开进场窗口。
          replayKey: Object.hash(_preview, _report),
          child: ListView(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
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

  Widget _buildPreview(ThemeData theme, ExternalReaderImportPreview preview) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final double? progress = _progressValue;
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.hoshi_import_summary_books(
              newBooks: preview.newBooks,
              existingBooks: preview.existingBooks,
              statsOnlyBooks: preview.statsOnlyBooks,
            ),
            style: type.bodyLarge,
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            t.hoshi_import_summary_records(
              records: preview.statRecords,
              positions: preview.positions,
            ),
            style: type.bodyMedium.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (preview.profileName.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              t.hoshi_import_summary_profile(name: preview.profileName),
              style: type.bodySmall.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          SizedBox(height: tokens.spacing.card),
          if (_running) ...<Widget>[
            // 进度：Display 大数字百分比 + M3E 波浪进度条。
            if (progress != null)
              Text(
                '${(progress * 100).floor()}%',
                style: type.displaySmallEmphasized.tabular.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            SizedBox(height: tokens.spacing.gap),
            FushiLinearProgressIndicator(value: progress, minHeight: 8),
            if (_progressLabel != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                _progressLabel!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.bodyMedium,
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FushiTextButton(
                onPressed: _cancelRequested
                    ? null
                    : () => setState(() => _cancelRequested = true),
                child: Text(t.cancel),
              ),
            ),
          ] else
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FushiFilledButton.icon(
                size: FushiButtonSize.m,
                onPressed: _runImport,
                icon: const FushiIcon(FushiIcons.download),
                label: Text(t.hoshi_import_run_start),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReport(ThemeData theme, ExternalReaderImportReport report) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final FushiCardTone tone = report.cancelled
        ? FushiCardTone.tertiary
        : FushiCardTone.primary;
    final Color? onTone = fushiCardToneColors(context, tone)?.onContainer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 结果：完成 = primary 色块，被取消 = tertiary 色块。
        FushiCard(
          tone: tone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  FushiIcon(
                    report.cancelled ? FushiIcons.info : FushiIcons.success,
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  Expanded(
                    child: Text(
                      report.cancelled
                          ? t.hoshi_import_result_cancelled
                          : t.hoshi_import_result_done,
                      style: type.titleLargeEmphasized.copyWith(color: onTone),
                    ),
                  ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.hoshi_import_result_books(
                  imported: report.booksImported,
                  matched: report.booksMatched,
                ),
                style: type.bodyLarge.copyWith(color: onTone),
              ),
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                t.hoshi_import_result_stats(
                  sessions: report.sessionsImported,
                  days: report.daysImported,
                  positions: report.positionsWritten,
                ),
                style: type.bodyMedium.copyWith(color: onTone),
              ),
              if (report.legacyRecordsSkipped > 0) ...<Widget>[
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.hoshi_import_result_legacy_skipped(
                    count: report.legacyRecordsSkipped,
                  ),
                  style: type.bodySmall.copyWith(color: onTone),
                ),
              ],
              if (report.segmentsSuppressedByDeletion > 0) ...<Widget>[
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.hoshi_import_result_deleted_skipped(
                    count: report.segmentsSuppressedByDeletion,
                  ),
                  style: type.bodySmall.copyWith(color: onTone),
                ),
              ],
            ],
          ),
        ),
        if (report.failures.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          FushiSectionTitle.group(
            t.hoshi_import_result_failed(count: report.failures.length),
            padding: EdgeInsets.zero,
          ),
          SizedBox(height: tokens.spacing.gap),
          for (int i = 0; i < report.failures.length; i++)
            FushiGroupedListItem(
              index: i,
              count: report.failures.length,
              child: FushiListItem(
                leading: const FushiListLeadingIcon(
                  FushiIcons.error,
                  tone: FushiCardTone.error,
                ),
                title: Text(report.failures[i].title),
                subtitle: Text(report.failures[i].reason),
                titleMaxLines: 2,
              ),
            ),
        ],
      ],
    );
  }
}
