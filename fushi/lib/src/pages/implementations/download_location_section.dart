part of 'torrent_settings_section.dart';

// 「下载位置」分组是 torrent_settings_section 库的一部分（part）：它读 AppModel，
// 作为独立库会把自己接进 AppModel 所在的 import 环（import_cycle_guard）；
// torrent 设置分区本来就在环里，挂在它下面不新增在环文件。

/// 用户对「改下载根时搬不搬已下载内容」的回答。
enum DownloadRootMoveChoice { move, newDownloadsOnly }

/// 「下载位置」设置分组：一个总下载根 + 各下载域的实际路径（只读）。
///
/// 从 torrent 分区挪出来的通用位置：下载根不只管内置 torrent 引擎，在线漫画、
/// 音乐插件、发现页下载全都落在它的子目录里（[DownloadLayout]），所以不再只在
/// 「内置引擎」分支渲染。
class DownloadLocationSection extends ConsumerStatefulWidget {
  const DownloadLocationSection({super.key});

  @override
  ConsumerState<DownloadLocationSection> createState() =>
      _DownloadLocationSectionState();
}

class _DownloadLocationSectionState
    extends ConsumerState<DownloadLocationSection> {
  DownloadLayout? _layout;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadLayout());
  }

  Future<void> _reloadLayout() async {
    final AppModel app = ref.read(appProvider);
    if (!app.isDatabaseReady) return;
    final DownloadLayout layout = await app.currentDownloadLayout();
    if (mounted) setState(() => _layout = layout);
  }

  /// 还有在往可搬目录里写的下载任务时的原因（null = 可以搬）。
  Future<String?> _busyReason() async {
    final AppModel app = ref.read(appProvider);
    final List<MangaDownloadJobRow> jobs = await app.mangaDownloadService
        .listJobs();
    final bool mangaBusy = jobs.any(
      (MangaDownloadJobRow job) =>
          job.status == MangaDownloadJobStatus.queued ||
          job.status == MangaDownloadJobStatus.running,
    );
    final InterconnectDownloadManager downloads = ref.read(
      interconnectDownloadManagerProvider,
    );
    final bool musicBusy = downloads.tasks.entries.any(
      (MapEntry<String, InterconnectDownloadTask> e) =>
          e.key.startsWith('music-plugin:') && e.value.isRunning,
    );
    return mangaBusy || musicBusy ? t.download_location_move_failed_busy : null;
  }

  Future<void> _change({required bool reset}) async {
    if (_busy) return;
    final AppModel app = ref.read(appProvider);
    setState(() => _busy = true);
    try {
      String target = '';
      if (!reset) {
        final String? picked = await pickRealDirectoryPath(
          context: context,
          appModel: app,
          dialogTitle: t.download_save_root_change,
          initialDirectory: app.downloadSaveRoot,
        );
        if (picked == null || picked.trim().isEmpty || !mounted) return;
        target = picked.trim();
        final DownloadLayout? current = _layout;
        if (current != null && p.equals(current.root, target)) return;
      }
      bool move = false;
      if (await app.downloadRootHasMovableContent()) {
        if (!mounted) return;
        final DownloadRootMoveChoice? choice =
            await showAppDialog<DownloadRootMoveChoice>(
              context: context,
              builder: (BuildContext ctx) => const _MoveChoiceDialog(),
            );
        if (choice == null || !mounted) return;
        move = choice == DownloadRootMoveChoice.move;
      }
      final String? busy = move ? await _busyReason() : null;
      if (!mounted) return;
      final NavigatorState navigator = Navigator.of(
        context,
        rootNavigator: true,
      );
      if (move && busy == null) {
        unawaited(
          showAppDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext ctx) =>
                const PopScope<Object?>(canPop: false, child: _MovingDialog()),
          ),
        );
        await WidgetsBinding.instance.endOfFrame;
      }
      final ({DownloadSaveRootIssue? issue, DownloadRootMoveReport? move})
      result;
      try {
        result = await app.changeDownloadSaveRoot(
          target,
          moveContent: move,
          busyReason: busy,
        );
      } finally {
        if (move && busy == null) navigator.pop();
      }
      _report(result.issue, result.move);
      await _reloadLayout();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _report(DownloadSaveRootIssue? issue, DownloadRootMoveReport? report) {
    if (issue != null) {
      FushiToast.show(
        msg: downloadSaveRootIssueMessage(issue),
        severity: ToastSeverity.error,
      );
      return;
    }
    if (report == null) return;
    final DownloadRootMoveFailure? failure = report.failure;
    if (failure != null) {
      final String detail = report.detail ?? '';
      FushiToast.show(
        msg: switch (failure) {
          DownloadRootMoveFailure.busy => t.download_location_move_failed_busy,
          DownloadRootMoveFailure.nested =>
            t.download_location_move_failed_nested,
          DownloadRootMoveFailure.copyFailed =>
            t.download_location_move_failed_copy(reason: detail),
          DownloadRootMoveFailure.databaseFailed =>
            t.download_location_move_failed_db(reason: detail),
        },
        severity: ToastSeverity.error,
      );
      return;
    }
    if (report.leftoverDirectories.isNotEmpty) {
      FushiToast.show(
        msg: t.download_location_move_leftovers(
          paths: report.leftoverDirectories.join('\n'),
        ),
        severity: ToastSeverity.warning,
      );
      return;
    }
    if (report.movedDomains.isNotEmpty) {
      FushiToast.show(
        msg: t.download_location_move_done,
        severity: ToastSeverity.success,
      );
    }
  }

  /// 各下载域的实际路径（只读）。torrent 行只在内置引擎生效时出现：外接 qBittorrent
  /// 的落盘目录由 qb 自己管。音乐插件在 iOS 上不存在（商店合规）。
  List<({String title, String path})> _domains(
    AppModel app,
    DownloadLayout layout,
  ) {
    final QbConnectionConfig config = effectiveTorrentConfig(
      app.qbConnectionConfig,
    );
    final bool embedded =
        config.resolveBackend(embeddedSupported: app.supportsEmbeddedTorrent) ==
        QbConnectionConfig.backendEmbedded;
    return <({String title, String path})>[
      if (embedded)
        (
          title: t.download_location_domain_torrent,
          path: p.join(layout.root, config.category),
        ),
      (
        title: t.download_location_domain_discovery,
        path: DownloadLayout.domainPath(layout.root, kDownloadDiscoveryDirName),
      ),
      (title: t.download_location_domain_manga, path: layout.mangaRoot),
      if (StoreRestrictedCapability.onlineMusicSource.isAvailable)
        (title: t.download_location_domain_music, path: layout.musicRoot),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppModel app = ref.watch(appProvider);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final DownloadSaveRootIssue? issue = app.downloadSaveRootIssue;
    final DownloadLayout? layout = _layout;
    final String root = layout?.root ?? app.downloadSaveRoot;
    final List<Widget> groups = <Widget>[
      Column(
        key: const ValueKey<String>('downloads.group.save_root'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdaptiveSettingsSection(
            title: t.download_location_title,
            children: <Widget>[
              SettingsSearchTarget(
                key: const ValueKey<String>('downloads.save_root'),
                id: 'downloads.save_root',
                child: AdaptiveSettingsRow(
                  title: t.download_save_root_title,
                  subtitle: root,
                  onTap: _busy ? null : () => _change(reset: false),
                  trailing: FushiFilledButton.tonal(
                    onPressed: _busy ? null : () => _change(reset: false),
                    child: Text(t.download_save_root_change),
                  ),
                ),
              ),
              if (!app.downloadSaveRootIsDefault)
                AdaptiveSettingsRow(
                  key: const ValueKey<String>('downloads.save_root_reset'),
                  title: t.download_save_root_reset,
                  onTap: _busy ? null : () => _change(reset: true),
                ),
              if (issue != null)
                Padding(
                  key: const ValueKey<String>('downloads.save_root_issue'),
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.rowHorizontal,
                    vertical: 10,
                  ),
                  child: FushiInlineNotice(
                    severity: FushiNoticeSeverity.warning,
                    message:
                        '${t.download_save_root_fallback_warning}'
                        '\n${app.downloadSaveRootRejectedPath ?? ''} — '
                        '${downloadSaveRootIssueMessage(issue)}',
                  ),
                ),
            ],
          ),
          SettingsSectionFooter(t.download_location_hint),
        ],
      ),
      if (layout != null)
        AdaptiveSettingsSection(
          key: const ValueKey<String>('downloads.group.domains'),
          children: <Widget>[
            for (final ({String title, String path}) domain in _domains(
              app,
              layout,
            ))
              AdaptiveSettingsRow(
                key: ValueKey<String>('downloads.domain.${domain.title}'),
                title: domain.title,
                subtitle: domain.path,
              ),
          ],
        ),
    ];
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < groups.length; i++)
            FushiStaggeredEntrance(index: i, child: groups[i]),
        ],
      ),
    );
  }
}

/// 「搬不搬已下载内容」三选一：搬过去 / 只用于新下载 / 取消（返回 null）。
class _MoveChoiceDialog extends StatelessWidget {
  const _MoveChoiceDialog();

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      child: FushiModalSheetFrame(
        title: t.download_location_move_title,
        leadingIcon: FushiIcons.moveFile,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.all(tokens.spacing.card),
        body: Text(
          t.download_location_move_message,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(
                context,
                DownloadRootMoveChoice.newDownloadsOnly,
              ),
              child: Text(t.download_location_keep_action),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () =>
                  Navigator.pop(context, DownloadRootMoveChoice.move),
              child: Text(t.download_location_move_action),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搬移进行中的阻塞弹窗（不可点遮罩 / 返回关闭）。
class _MovingDialog extends StatelessWidget {
  const _MovingDialog();

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 360,
      scrollable: false,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.download_location_moving, style: tokens.type.listTitle),
            SizedBox(height: tokens.spacing.gap),
            const FushiLinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
