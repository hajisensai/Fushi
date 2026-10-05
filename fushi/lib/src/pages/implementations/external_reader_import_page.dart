import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/sync/external_reader_import/external_reader_import_service.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _running) setState(() => _cancelRequested = true);
      },
      child: Scaffold(
        appBar: FushiAppBar(title: Text(t.hoshi_import_entry)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(t.hoshi_import_how_to),
            const SizedBox(height: 16),
            FushiFilledButton.tonalIcon(
              onPressed: _scanning || _running ? null : _pickBackup,
              icon: const FushiIcon(Icons.folder_open_outlined),
              label: Text(t.hoshi_import_file_pick),
            ),
            const SizedBox(height: 16),
            if (_scanning) ...<Widget>[
              FushiLoadingView(message: t.hoshi_import_scan_running),
            ],
            // 错误走共享提示块（中性底 + 错误色图标），不再是裸红字。
            if (_error != null)
              FushiInlineNotice(
                severity: FushiNoticeSeverity.error,
                message: _error!,
              ),
            if (_preview != null) _buildPreview(theme, _preview!),
            if (_report != null) _buildReport(theme, _report!),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme, ExternalReaderImportPreview preview) {
    return FushiCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.hoshi_import_summary_books(
              newBooks: preview.newBooks,
              existingBooks: preview.existingBooks,
              statsOnlyBooks: preview.statsOnlyBooks,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.hoshi_import_summary_records(
              records: preview.statRecords,
              positions: preview.positions,
            ),
          ),
          if (preview.profileName.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              t.hoshi_import_summary_profile(name: preview.profileName),
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          if (_running) ...<Widget>[
            FushiLinearProgressIndicator(value: _progressValue),
            if (_progressLabel != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _progressLabel!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
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
            FushiFilledButton(
              onPressed: _runImport,
              child: Text(t.hoshi_import_run_start),
            ),
        ],
      ),
    );
  }

  Widget _buildReport(ThemeData theme, ExternalReaderImportReport report) {
    return FushiCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            report.cancelled
                ? t.hoshi_import_result_cancelled
                : t.hoshi_import_result_done,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            t.hoshi_import_result_books(
              imported: report.booksImported,
              matched: report.booksMatched,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.hoshi_import_result_stats(
              sessions: report.sessionsImported,
              days: report.daysImported,
              positions: report.positionsWritten,
            ),
          ),
          if (report.legacyRecordsSkipped > 0) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              t.hoshi_import_result_legacy_skipped(
                count: report.legacyRecordsSkipped,
              ),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (report.segmentsSuppressedByDeletion > 0) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              t.hoshi_import_result_deleted_skipped(
                count: report.segmentsSuppressedByDeletion,
              ),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (report.failures.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              t.hoshi_import_result_failed(count: report.failures.length),
              style: TextStyle(color: theme.colorScheme.error),
            ),
            for (final ExternalReaderImportFailure failure in report.failures)
              FushiListItem(
                density: FushiListDensity.compact,
                leading: FushiIcon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                ),
                title: Text(failure.title),
                subtitle: Text(failure.reason),
                titleMaxLines: 2,
              ),
          ],
        ],
      ),
    );
  }
}
