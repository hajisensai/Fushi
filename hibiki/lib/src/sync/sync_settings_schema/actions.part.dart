// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Manual sync action row (sync-now) + sync-report summary.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

/// 手动同步完成后的 SnackBar 摘要（消费 [SyncRunReport]）。纯函数，便于单测边界：
/// 全 0 → "无新增"；多类型 → ` · ` 拼接；有失败 → 追加失败计数后缀。
@visibleForTesting
String summarizeSyncReport(SyncRunReport r) {
  final List<String> parts = <String>[
    if (r.booksImported > 0) t.sync_now_books_in(count: r.booksImported),
    if (r.dictionariesImported > 0)
      t.sync_now_dicts_in(count: r.dictionariesImported),
    if (r.dictionariesExported > 0)
      t.sync_now_dicts_out(count: r.dictionariesExported),
    if (r.audiobooksImported > 0)
      t.sync_now_audio_in(count: r.audiobooksImported),
    if (r.audiobooksExported > 0)
      t.sync_now_audio_out(count: r.audiobooksExported),
    if (r.localAudioImported > 0)
      t.sync_now_local_audio_in(count: r.localAudioImported),
    if (r.localAudioExported > 0)
      t.sync_now_local_audio_out(count: r.localAudioExported),
  ];
  final String head = parts.isEmpty ? t.sync_now_no_changes : parts.join(' · ');
  final String done = t.sync_now_done(detail: head);
  return r.errors.isEmpty
      ? done
      : '$done${t.sync_now_failed_suffix(count: r.errors.length)}';
}

// ── Backup export widget ─────────────────────────────────────────────

class _SyncNowWidget extends StatefulWidget {
  const _SyncNowWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SyncNowWidget> createState() => _SyncNowWidgetState();
}

class _SyncNowWidgetState extends State<_SyncNowWidget> {
  Future<void> _syncNow() async {
    // Re-entrant / already-in-flight guard: the whole row is a focus target
    // whose Activate (A/Enter, see [AdaptiveSettingsRow.onTap] below) runs this
    // too, AND a background/app-open auto-sync may already hold the sweep lock.
    // In both cases a second trigger is a no-op — the global [syncInProgress]
    // notifier already drives the inline bar (BUG-101), so there's nothing to do
    // here but let it run.
    if (syncInProgress.value) return;
    try {
      final AppModel appModel = widget.settingsContext.appModel;
      final ManualSyncResult result = await runManualFullSync(
        db: appModel.database,
        dictionaryResourceRoot: appModel.dictionaryResourceDirectory,
        audioDatabaseRoot:
            Directory('${appModel.appDirectory.path}/audiobooks'),
        tempDir: appModel.temporaryDirectory,
        localAudioEntries: appModel.localAudioDbs,
        onLocalAudioImported: appModel.importSyncedLocalAudioDb,
        onPostRun: appModel.refreshAfterSyncRun,
      );
      if (!mounted) return;
      switch (result.outcome) {
        case ManualSyncOutcome.notConfigured:
          _showSnackBar(context, t.sync_compare_unavailable);
        case ManualSyncOutcome.busy:
          _showSnackBar(context, t.sync_now_busy);
        case ManualSyncOutcome.completed:
          final SyncRunReport report = result.report!;
          _showSnackBar(context, summarizeSyncReport(report));
          if (report.conflicts.isNotEmpty) {
            // Manual sync is an explicit user action: prompt resolution
            // immediately, unconstrained by in-book/snooze (ConflictSource
            // .manual). Re-resolve the backend (auth was just exercised by the
            // run, so this is cheap) to drive the conflicts-only dialog.
            final SyncBackend backend = resolveSyncBackend(
              await SyncRepository(appModel.database).getBackendType(),
            );
            await appModel.syncConflictPrompter.present(
              navigatorKey: appModel.navigatorKey,
              db: appModel.database,
              backend: backend,
              conflicts: report.conflicts,
              source: ConflictSource.manual,
              inBook: appModel.isMediaOpen,
            );
          }
      }
    } on SyncAuthError catch (e) {
      // TODO-836: insufficient_scope (or any auth error) — the saved session is
      // no longer usable. Sign out so the account row falls back to "not signed
      // in" (the sign-in button reappears), then prompt re-login. The sign-out
      // sequence mirrors the manual sign-out path in account.part.dart.
      final AppModel appModel = widget.settingsContext.appModel;
      final SyncRepository repo = SyncRepository(appModel.database);
      try {
        final SyncBackend backend =
            resolveSyncBackend(await repo.getBackendType());
        await backend.signOut(repo: repo);
        backend.clearCache();
        await repo.clearFolderCache();
      } catch (_) {
        // Best-effort sign-out; never hide the original re-login prompt.
      }
      if (mounted) _showSnackBar(context, friendlySyncError(e));
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          context,
          t.sync_error(message: friendlySyncErrorDetail(e)),
        );
      }
    }
    // No local teardown: the inline bar is driven by the global [syncInProgress]
    // / [syncProgress] notifiers, which the sync entry points reset in their own
    // finally blocks.
  }

  /// Localized phase name for the inline progress line.
  String _phaseLabel(SyncPhase phase) {
    switch (phase) {
      case SyncPhase.books:
        return t.sync_progress_books;
      case SyncPhase.readingData:
        return t.sync_progress_reading;
      case SyncPhase.dictionaries:
        return t.sync_progress_dictionaries;
      case SyncPhase.localAudio:
        return t.sync_progress_local_audio;
      case SyncPhase.audiobooks:
        return t.sync_progress_audiobooks;
    }
  }

  /// "phase (k/N) title" — count omitted when the phase has no items.
  String _progressLine(SyncProgress p) {
    final String phase = _phaseLabel(p.phase);
    if (p.itemTotal <= 0) return phase;
    final String head = '$phase (${p.itemIndex + 1}/${p.itemTotal})';
    final String? title = p.title;
    return (title == null || title.isEmpty) ? head : '$head $title';
  }

  @override
  Widget build(BuildContext context) {
    // Driven by the app-wide notifiers, NOT a local flag: the bar must show for
    // ANY in-flight sweep — including a background/app-open auto-sync the user
    // never triggered from this row — instead of only the run this row started
    // (which used to fall through to a bare "同步进行中" toast, BUG-101).
    return ValueListenableBuilder<bool>(
      valueListenable: syncInProgress,
      builder: (BuildContext context, bool syncing, _) {
        return ValueListenableBuilder<SyncProgress?>(
          valueListenable: syncProgress,
          builder: (BuildContext context, SyncProgress? p, __) {
            final AdaptiveSettingsRow row = AdaptiveSettingsRow(
              title: t.sync_now,
              subtitle:
                  syncing && p != null ? _progressLine(p) : t.sync_now_hint,
              icon: Icons.sync,
              controlBelow: true,
              // The action lives on the trailing button; giving the ROW an onTap
              // is what registers it as a HibikiFocusTarget so gamepad/keyboard
              // directional nav can reach it and Activate runs the sync
              // (BUG-016). Without it the row was unreachable and Down from the
              // neighbouring "Compare Data" row jumped cross-pane to the rail.
              onTap: _syncNow,
              trailing: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton(
                      onPressed: _syncNow,
                      child: Text(t.sync_now),
                    ),
            );
            if (!syncing) return row;
            // Inline determinate bar below the row (indeterminate when a phase
            // has no measurable total), matching the compare dialog's Apply
            // progress.
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                row,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: LinearProgressIndicator(value: p?.fraction),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
