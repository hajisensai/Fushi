part of 'update_checker.dart';

@visibleForTesting
String formatUpdateDownloadByteCount(int? bytes) {
  if (bytes == null) return '—';
  if (bytes.abs() < 1024) return '$bytes B';

  const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value.abs() >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
}

@visibleForTesting
String formatUpdateDownloadSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null || !bytesPerSecond.isFinite) return '—';
  if (bytesPerSecond < 0) return '—';
  return '${formatUpdateDownloadByteCount(bytesPerSecond.round())}/s';
}

@visibleForTesting
double? updateDownloadBytesPerSecond({
  required int startedBytes,
  required int receivedBytes,
  required Duration elapsed,
}) {
  if (elapsed <= Duration.zero) return null;
  final int delta = receivedBytes - startedBytes;
  if (delta <= 0) return 0;
  return delta * Duration.microsecondsPerSecond / elapsed.inMicroseconds;
}

@visibleForTesting
class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({
    required this.version,
    required this.releaseNotes,
    required this.primaryLabel,
    required this.onPrimary,
    super.key,
  });

  final String version;
  final String releaseNotes;
  final String primaryLabel;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.9,
      scrollable: false,
      insetPadding: EdgeInsets.all(tokens.spacing.gap),
      child: HibikiModalSheetFrame(
        title: t.update_available,
        leadingIcon: Icons.system_update_alt_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t.update_message(version: version),
              style: tokens.type.listSubtitle,
            ),
            if (releaseNotes.isNotEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              MarkdownBody(
                data: releaseNotes,
                selectable: true,
                onTapLink: (_, href, __) {
                  if (href == null) return;
                  launchUrl(
                    Uri.parse(href),
                    mode: LaunchMode.externalApplication,
                  );
                },
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: tokens.type.listSubtitle,
                ),
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.update_skip),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: onPrimary,
              child: Text(primaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// BUG-427/TODO-852: shown when the Android install fails because the
/// "install unknown apps" permission is not yet granted. The user is sent to
/// the system setting by the native side; this dialog lets them retry the
/// install (reusing the already-downloaded apk) once they return, or cancel.
/// Pops `true` to retry, `false`/dismiss to cancel.
class InstallPermissionRetryDialog extends StatelessWidget {
  const InstallPermissionRetryDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.9,
      scrollable: false,
      insetPadding: EdgeInsets.all(tokens.spacing.gap),
      child: HibikiModalSheetFrame(
        title: t.update_install_permission_title,
        leadingIcon: Icons.security_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.update_install_permission_message,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t.update_install_permission_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t.update_install_permission_retry),
            ),
          ],
        ),
      ),
    );
  }
}

class WindowsUpdateHandoffResultDialog extends StatelessWidget {
  const WindowsUpdateHandoffResultDialog({
    required this.result,
    super.key,
  });

  final WindowsUpdateHandoffResult result;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final WindowsUpdateHandoffRecord record = result.record;
    final String title = switch (result.status) {
      WindowsUpdateHandoffStatus.installed => t.update_install_success_title,
      WindowsUpdateHandoffStatus.incomplete =>
        t.update_install_incomplete_title,
      WindowsUpdateHandoffStatus.launchFailed =>
        t.update_install_launch_failed_title,
    };
    final String message = switch (result.status) {
      WindowsUpdateHandoffStatus.installed =>
        t.update_install_success_message(version: record.targetVersion),
      WindowsUpdateHandoffStatus.incomplete =>
        t.update_install_incomplete_message,
      WindowsUpdateHandoffStatus.launchFailed =>
        t.update_install_launch_failed_message(version: record.targetVersion),
    };
    final IconData icon = switch (result.status) {
      WindowsUpdateHandoffStatus.installed => Icons.check_circle_outline,
      WindowsUpdateHandoffStatus.incomplete => Icons.error_outline,
      WindowsUpdateHandoffStatus.launchFailed => Icons.warning_amber_outlined,
    };

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.9,
      scrollable: false,
      insetPadding: EdgeInsets.all(tokens.spacing.gap),
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: icon,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              message,
              style: tokens.type.listSubtitle,
            ),
            if (result.status != WindowsUpdateHandoffStatus.installed) ...[
              if (record.installerFailureSummary != null) ...[
                SizedBox(height: tokens.spacing.gap),
                SelectableText(
                  t.update_install_failure_summary(
                    summary: record.installerFailureSummary!,
                  ),
                  style: tokens.type.listSubtitle,
                ),
              ],
              SizedBox(height: tokens.spacing.gap),
              SelectableText(
                t.update_install_log_path(path: record.innoLogPath),
                style: tokens.type.listSubtitle,
              ),
              if (record.currentExecutablePath != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_current_executable(
                    path: record.currentExecutablePath!,
                  ),
                  style: tokens.type.metadata,
                ),
              ],
              if (record.targetInstallDir != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_target_dir(path: record.targetInstallDir!),
                  style: tokens.type.metadata,
                ),
              ],
              for (final WindowsDetectedInstallLocation location
                  in record.detectedInstallLocations)
                if (location.path.isNotEmpty) ...[
                  SizedBox(height: tokens.spacing.gap / 2),
                  SelectableText(
                    t.update_install_detected_location(
                      source: location.source,
                      path: location.path,
                    ),
                    style: tokens.type.metadata,
                  ),
                ],
              if (record.pathMismatchWarning != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_path_mismatch(
                    warning: record.pathMismatchWarning!,
                  ),
                  style: tokens.type.metadata,
                ),
              ],
              for (final WindowsProcessInfo process
                  in record.runningHibikiProcesses) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_running_process(
                    pid: process.pid,
                    path: _windowsProcessPathLabel(process),
                  ),
                  style: tokens.type.metadata,
                ),
              ],
              for (final WindowsProcessInfo process
                  in record.libmpvModuleHolders) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_libmpv_holder(
                    pid: process.pid,
                    path: _windowsProcessPathLabel(process),
                  ),
                  style: tokens.type.metadata,
                ),
              ],
              for (final WindowsInnoDeleteFileFailure failure
                  in record.innoLogDeleteFileFailures) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_deletefile_failure(
                    path: failure.path,
                    code: failure.code,
                  ),
                  style: tokens.type.metadata,
                ),
              ],
              if (record.runningHibikiProcesses.isNotEmpty ||
                  record.libmpvModuleHolders.isNotEmpty ||
                  record.innoLogDeleteFileFailures.isNotEmpty) ...[
                SizedBox(height: tokens.spacing.gap),
                Text(
                  t.update_install_manual_close_retry,
                  style: tokens.type.listSubtitle,
                ),
              ],
              if (record.diagnostics.hasLockEvidence) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.update_install_restart_windows_hint,
                  style: tokens.type.listSubtitle,
                ),
              ],
              if (record.launcherPid != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_launcher_pid(pid: record.launcherPid!),
                  style: tokens.type.metadata,
                ),
              ],
              if (record.parentExitObserved != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  record.parentExitObserved!
                      ? t.update_install_parent_exit_observed
                      : t.update_install_parent_exit_not_observed,
                  style: tokens.type.metadata,
                ),
              ],
              if (record.installerPid != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  t.update_install_installer_pid(pid: record.installerPid!),
                  style: tokens.type.metadata,
                ),
              ],
              if (record.innoLogExists != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  record.innoLogExists!
                      ? t.update_install_log_observed
                      : t.update_install_log_not_observed,
                  style: tokens.type.metadata,
                ),
              ],
              if (record.launchError != null) ...[
                SizedBox(height: tokens.spacing.gap / 2),
                SelectableText(
                  record.launchError!,
                  style: tokens.type.metadata,
                ),
              ],
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}

String _windowsProcessPathLabel(WindowsProcessInfo process) {
  return process.path ?? process.name ?? 'unknown';
}

@visibleForTesting
Widget buildUpdateDownloadOverlayForTest({
  required ValueNotifier<double> progress,
  required ValueNotifier<String> status,
  required ValueNotifier<UpdateDownloadDiagnostics?> diagnostics,
  required VoidCallback onHide,
  VoidCallback? onCancel,
}) {
  return _DownloadOverlay(
    progress: progress,
    status: status,
    diagnostics: diagnostics,
    onHide: onHide,
    onCancel: onCancel ?? () {},
  );
}

class _DownloadOverlay extends StatelessWidget {
  const _DownloadOverlay({
    required this.progress,
    required this.status,
    required this.diagnostics,
    required this.onHide,
    required this.onCancel,
  });
  final ValueNotifier<double> progress;
  final ValueNotifier<String> status;
  final ValueNotifier<UpdateDownloadDiagnostics?> diagnostics;
  final VoidCallback onHide;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Positioned.fill(
      child: Material(
        color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.54),
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.gap,
              vertical: tokens.spacing.gap,
            ),
            child: HibikiCard(
              margin: EdgeInsets.zero,
              padding: EdgeInsets.all(tokens.spacing.card),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<String>(
                      valueListenable: status,
                      builder: (_, s, __) => Text(
                        s,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    ValueListenableBuilder<double>(
                      valueListenable: progress,
                      builder: (_, p, __) {
                        // 双层防线：渲染前 clamp(0,1)，防任何上游异常进度值
                        // （>100% / 负值）穿透到进度条与百分比文字（TODO-628/650）。
                        final double clamped = p.clamp(0.0, 1.0);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(
                              value: clamped > 0 ? clamped : null,
                            ),
                            SizedBox(height: tokens.spacing.gap / 2),
                            Text('${(clamped * 100).toStringAsFixed(0)}%'),
                          ],
                        );
                      },
                    ),
                    ValueListenableBuilder<UpdateDownloadDiagnostics?>(
                      valueListenable: diagnostics,
                      builder: (_, value, __) {
                        if (value == null) return const SizedBox.shrink();
                        return Padding(
                          padding: EdgeInsets.only(top: tokens.spacing.gap),
                          child: _DownloadDiagnosticsPanel(value: value),
                        );
                      },
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        // 取消（逃生口·TODO-738）：全死源串行回退期间用户可主动中断，
                        // 不必盯着「正在连接更新源…」干等几分钟。
                        TextButton(
                          onPressed: onCancel,
                          child: Text(t.update_cancel),
                        ),
                        TextButton(
                          onPressed: onHide,
                          child: Text(t.update_hide),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DownloadDiagnosticsPanel extends StatelessWidget {
  const _DownloadDiagnosticsPanel({required this.value});

  final UpdateDownloadDiagnostics value;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? style = Theme.of(context).textTheme.bodySmall;
    final String resumeStatus = value.restartedFromZero
        ? t.update_download_restarted_from_zero
        : value.resumed
            ? t.update_download_resumed
            : t.update_download_not_resumed;
    return DefaultTextStyle.merge(
      style: style,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DiagnosticLine(
            text: t.update_download_source(source: value.sourceHost),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          _DiagnosticLine(
            text: t.update_download_size(
              received: formatUpdateDownloadByteCount(value.receivedBytes),
              total: formatUpdateDownloadByteCount(value.totalBytes),
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          _DiagnosticLine(
            text: t.update_download_speed(
              speed: formatUpdateDownloadSpeed(value.bytesPerSecond),
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          _DiagnosticLine(
            text: t.update_download_resume_status(status: resumeStatus),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticLine extends StatelessWidget {
  const _DiagnosticLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      softWrap: true,
    );
  }
}
