/// 同步与历史页的「存储换代预检」一节：上一次换代预演（sync2/srs_gen4_rehearsal.dart）的结论；没过的库给出诊断报告
/// 的导出入口。报告只含 ID 与计数、不含卡片内容。没跑过预演时整节不显示。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_gen4_rehearsal.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 结论的标题。
String srsGen4RehearsalTitle(SrsGen4RehearsalVerdict v) => switch (v) {
  SrsGen4RehearsalVerdict.pass ||
  SrsGen4RehearsalVerdict.empty => t.srs_gen4_rehearsal_pass,
  SrsGen4RehearsalVerdict.fail => t.srs_gen4_rehearsal_fail,
  SrsGen4RehearsalVerdict.blocked => t.srs_gen4_rehearsal_blocked,
  SrsGen4RehearsalVerdict.skipped ||
  SrsGen4RehearsalVerdict.cancelled ||
  SrsGen4RehearsalVerdict.error => t.srs_gen4_rehearsal_unfinished,
};

/// 这个结论要不要给诊断报告的导出入口（过了的、没数据的不给）。
bool srsGen4RehearsalNeedsDiagnostics(SrsGen4RehearsalVerdict v) =>
    v != SrsGen4RehearsalVerdict.pass && v != SrsGen4RehearsalVerdict.empty;

class SrsGen4RehearsalSection extends ConsumerStatefulWidget {
  const SrsGen4RehearsalSection({super.key});

  @override
  ConsumerState<SrsGen4RehearsalSection> createState() =>
      _SrsGen4RehearsalSectionState();
}

class _SrsGen4RehearsalSectionState
    extends ConsumerState<SrsGen4RehearsalSection> {
  SrsGen4RehearsalReport? _report;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) return;
      final SrsGen4RehearsalReport? r = await srsGen4RehearsalLastReport(
        store.core,
      );
      if (mounted) setState(() => _report = r);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsGen4RehearsalSection.load', e, stack);
    }
  }

  Future<void> _export(SrsGen4RehearsalReport report) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    File? file;
    try {
      final DateTime now = DateTime.now();
      final String stamp =
          '${now.year.toString().padLeft(4, '0')}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}-'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final String fileName = 'fushi-srs-upgrade-check-$stamp.json';
      final Directory tmp = await getTemporaryDirectory();
      file = File(p.join(tmp.path, fileName));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.raw),
      );
      if (isDesktop) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.srs_gen4_rehearsal_export,
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: <String>['json'],
        );
        if (savePath != null) {
          await file.copy(savePath);
          FushiToast.show(
            msg: t.srs_gen4_rehearsal_saved,
            severity: ToastSeverity.success,
          );
        }
      } else {
        await FushiShare.shareFiles(<XFile>[
          XFile(file.path, mimeType: 'application/json'),
        ], subject: t.srs_gen4_rehearsal_share_subject);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsGen4RehearsalSection.export', e, stack);
      FushiToast.show(
        msg: t.srs_gen4_rehearsal_export_failed(reason: e.toString()),
        severity: ToastSeverity.error,
      );
    } finally {
      // 移动端系统分享面板异步读文件，不能在 shareFiles 返回后立即删。
      if (isDesktop && file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final SrsGen4RehearsalReport? report = _report;
    if (report == null) return const SizedBox.shrink();
    final SrsGen4RehearsalVerdict v = report.verdict;
    final DateTime? at = report.finishedAt;
    final bool ok =
        v == SrsGen4RehearsalVerdict.pass || v == SrsGen4RehearsalVerdict.empty;
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('srs_gen4_rehearsal_section'),
      title: t.srs_gen4_rehearsal_section,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('srs_gen4_rehearsal_status'),
          title: srsGen4RehearsalTitle(v),
          subtitle: t.srs_gen4_rehearsal_checked_at(
            time: at == null ? '-' : srsTimeLabel(context, at),
            version: report.appVersion ?? '-',
          ),
          icon: ok
              ? FushiIcons.success
              : (v == SrsGen4RehearsalVerdict.fail
                    ? FushiIcons.error
                    : FushiIcons.warning),
          showIcon: true,
          subtitleMaxLines: 2,
        ),
        if (srsGen4RehearsalNeedsDiagnostics(v))
          AdaptiveSettingsNavigationRow(
            key: const ValueKey<String>('srs_gen4_rehearsal_export'),
            title: t.srs_gen4_rehearsal_export,
            subtitle: t.srs_gen4_rehearsal_export_hint,
            icon: FushiIcons.share,
            showIcon: true,
            onTap: () => unawaited(_export(report)),
          ),
      ],
    );
  }
}
