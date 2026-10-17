// GENERATED-NOTE: extracted from reader_fushi_history_page.dart (TODO-587).
part of '../reader_fushi_history_page.dart';

/// 书架删除确认弹窗。[onConfirm] 回传用户的 [DeleteDecision]：scope 来自「同步删除」
/// 勾选框（勾选=[DeleteScope.syncEverywhere] 记墓碑传播到其他设备；默认不勾=
/// [DeleteScope.keepLocalOnly] 只删本机），deleteLocalFiles 来自「同时删除本地文件」
/// 勾选框（仅 [localFilesSubtitle] 非 null 时渲染——书/PDF/漫画导入即拷贝进 app 目录、
/// 原件路径根本没入库，只有显式登记了 app 目录之外的原始音频路径的有声书/字幕书才有
/// 本机可删的原件）。副标题必须由调用方给出、如实说清删的是什么，不能回落到通用措辞。
/// [rememberedChoices] 恢复两个选项的默认值；「记住这些选择」只保存默认值，不跳过
/// 本确认框。
/// [showSyncScope]=false 时把同步勾选框换成 [DeleteScopeUnavailableNote] 说明行、恒
/// keepLocalOnly——由调用方按 `hasDeletionPropagationChannel` 传入：本机一个同步通道
/// 都没有时，那个勾选框兑现不了（TODO-2470 死角②）。取消返回 null。
/// 漫画作品页「移出漫画书架」也用它（BUG-2513），删除确认的披露与传播语义两处一致。
/// deleteStatistics 来自「同时删除统计数据」勾选（仅 [statisticsSubtitle] 非 null 时
/// 渲染；恒从未勾开始、不进「记住这些选择」，与视频删除确认同一纪律）。
class ReaderHistoryDeleteDialog extends StatefulWidget {
  const ReaderHistoryDeleteDialog({
    required this.title,
    required this.message,
    required this.onConfirm,
    this.showSyncScope = true,
    this.localFilesSubtitle,
    this.statisticsSubtitle,
    this.disclosure,
    this.rememberedChoices,
    this.onPersistChoices,
    super.key,
  });

  final String title;
  final String message;
  final ValueChanged<DeleteDecision> onConfirm;
  final bool showSyncScope;

  /// null = 这条目没有本机可删的原件 → 不渲染勾选框，恒 deleteLocalFiles=false。
  final String? localFilesSubtitle;

  /// null = 这个入口不提供「同时删除统计数据」→ 恒 deleteStatistics=false。
  /// 非 null = 渲染勾选行，副标题如实说清删掉的是哪些统计口径。
  final String? statisticsSubtitle;

  /// 逐项披露真实删除范围；null 表示该入口暂未接入结构化披露。
  final DeletionDisclosure? disclosure;
  final DeletePromptRememberedChoices? rememberedChoices;
  final Future<void> Function(DeletePromptRememberedChoices?)? onPersistChoices;

  @override
  State<ReaderHistoryDeleteDialog> createState() =>
      _ReaderHistoryDeleteDialogState();
}

class _ReaderHistoryDeleteDialogState extends State<ReaderHistoryDeleteDialog> {
  late bool _syncDelete;
  late bool _deleteLocalFiles;
  // 统计删除恒从未勾开始、不被记忆（见 [DeleteStatisticsRow]）。
  bool _deleteStatistics = false;
  late bool _rememberChoices;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _syncDelete = widget.rememberedChoices?.syncEverywhere ?? false;
    _deleteLocalFiles = widget.rememberedChoices?.deleteLocalFiles ?? false;
    _rememberChoices = widget.rememberedChoices != null;
  }

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    final DeletePromptRememberedChoices? choices = _rememberChoices
        ? DeletePromptRememberedChoices(
            syncEverywhere: _syncDelete,
            deleteLocalFiles: _deleteLocalFiles,
          )
        : null;
    try {
      await widget.onPersistChoices?.call(choices);
    } catch (error, stackTrace) {
      debugPrint('Delete prompt preference write failed: $error\n$stackTrace');
    }
    if (!mounted) return;
    widget.onConfirm(
      DeleteDecision(
        scope: widget.showSyncScope && _syncDelete
            ? DeleteScope.syncEverywhere
            : DeleteScope.keepLocalOnly,
        deleteLocalFiles:
            widget.localFilesSubtitle != null && _deleteLocalFiles,
        deleteStatistics:
            widget.statisticsSubtitle != null && _deleteStatistics,
      ),
    );
  }

  /// 披露跟着两个二级勾选翻面：勾了哪个，对应条目就从「会被保留」挪进「会被删除」。
  DeletionDisclosure _shownDisclosure(DeletionDisclosure base) {
    DeletionDisclosure shown = base;
    if (_deleteLocalFiles) shown = shown.withLocalFilesDeleted();
    if (_deleteStatistics) shown = shown.withStatisticsDeleted();
    return shown;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
        title: widget.title,
        leadingIcon: Icons.delete_outline,
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message, style: tokens.type.listSubtitle),
            if (widget.disclosure != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              DeletionDisclosureView(
                disclosure: _shownDisclosure(widget.disclosure!),
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            if (widget.showSyncScope)
              DeleteConfirmCheckboxRow(
                title: t.delete_scope_sync_everywhere,
                subtitle: _syncDelete
                    ? t.delete_scope_sync_everywhere_desc
                    : t.delete_scope_keep_local_desc,
                value: _syncDelete,
                onChanged: (bool v) => setState(() => _syncDelete = v),
              )
            else
              const DeleteScopeUnavailableNote(),
            // 破坏性最强的选项排在同步勾选框之后：它不该是列表第一行、也不该是
            // Tab 焦点第一个落点。
            if (widget.localFilesSubtitle != null)
              DeleteLocalFilesRow(
                value: _deleteLocalFiles,
                subtitle: widget.localFilesSubtitle!,
                onChanged: (bool v) => setState(() => _deleteLocalFiles = v),
              ),
            if (widget.statisticsSubtitle != null)
              DeleteStatisticsRow(
                value: _deleteStatistics,
                subtitle: widget.statisticsSubtitle!,
                onChanged: (bool v) => setState(() => _deleteStatistics = v),
              ),
            if (widget.showSyncScope || widget.localFilesSubtitle != null)
              DeleteRememberChoicesRow(
                value: _rememberChoices,
                onChanged: (bool v) => setState(() => _rememberChoices = v),
              ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, null),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: _saving ? null : _confirm,
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookProfileDialog extends StatefulWidget {
  const _BookProfileDialog({
    required this.bookUid,
    required this.profileRepo,
    required this.profiles,
    required this.activeProfileName,
  });

  final String bookUid;
  final ProfileRepository profileRepo;
  final List<ProfileRow> profiles;
  final String activeProfileName;

  @override
  State<_BookProfileDialog> createState() => _BookProfileDialogState();
}

class _BookProfileDialogState extends State<_BookProfileDialog> {
  int? _selectedProfileId;
  bool _loading = true;
  late List<ProfileRow> _profiles;
  late String _activeProfileName;

  @override
  void initState() {
    super.initState();
    _profiles = widget.profiles;
    _activeProfileName = widget.activeProfileName;
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final int? current = await widget.profileRepo.getBookProfileId(
      widget.bookUid,
    );

    if (_profiles.isEmpty || _activeProfileName.isEmpty) {
      _profiles = await widget.profileRepo.getAllProfiles();
      final int activeId = await widget.profileRepo.getActiveProfileId();
      for (final p in _profiles) {
        if (p.id == activeId) {
          _activeProfileName = p.name;
          break;
        }
      }
      if (_activeProfileName.isEmpty && _profiles.isNotEmpty) {
        _activeProfileName = _profiles.first.name;
      }
    }

    if (mounted) {
      setState(() {
        _selectedProfileId = current;
        _loading = false;
      });
    }
  }

  Future<void> _onChanged(int? profileId) async {
    setState(() => _selectedProfileId = profileId);
    if (profileId == null) {
      await widget.profileRepo.removeBookProfile(widget.bookUid);
    } else {
      await widget.profileRepo.setBookProfile(widget.bookUid, profileId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BookProfileDialogFrame(
      loading: _loading,
      activeProfileName: _activeProfileName,
      profiles: _profiles,
      selectedProfileId: _selectedProfileId,
      onChanged: _onChanged,
      onClose: () => Navigator.pop(context),
    );
  }
}

@visibleForTesting
class BookProfileDialogFrame extends StatelessWidget {
  const BookProfileDialogFrame({
    required this.loading,
    required this.activeProfileName,
    required this.profiles,
    required this.selectedProfileId,
    required this.onChanged,
    required this.onClose,
    super.key,
  });

  final bool loading;
  final String activeProfileName;
  final List<ProfileRow> profiles;
  final int? selectedProfileId;
  final ValueChanged<int?> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 500,
      maxHeightFactor: 0.86,
      // FushiModalSheetFrame manages its own header/body/footer layout and
      // scrolls its body internally. Leaving the dialog frame's default
      // scrollable:true would wrap it in a second SingleChildScrollView, giving
      // a confusing nested outer+inner double scroll. scrollable:false makes the
      // ConstrainedBox bound the sheet directly, matching every other dialog.
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.profile_book_profile,
        leadingIcon: Icons.manage_accounts_outlined,
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
        body: loading
            ? SizedBox(
                height: 64,
                child: Center(child: adaptiveIndicator(context: context)),
              )
            : BookProfileDialogContent(
                activeProfileName: activeProfileName,
                profiles: profiles,
                selectedProfileId: selectedProfileId,
                onChanged: onChanged,
              ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: FushiTextButton(onPressed: onClose, child: Text(t.dialog_close)),
        ),
      ),
    );
  }
}

@visibleForTesting
class BookProfileDialogContent extends StatelessWidget {
  const BookProfileDialogContent({
    required this.activeProfileName,
    required this.profiles,
    required this.selectedProfileId,
    required this.onChanged,
    super.key,
  });

  final String activeProfileName;
  final List<ProfileRow> profiles;
  final int? selectedProfileId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.46,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            AdaptiveSettingsSection(
              children: [
                _BookProfileOptionRow(
                  title: t.profile_follow_default_current(
                    name: activeProfileName,
                  ),
                  selected: selectedProfileId == null,
                  onTap: () => onChanged(null),
                ),
                for (final profile in profiles)
                  _BookProfileOptionRow(
                    title: profile.name,
                    selected: selectedProfileId == profile.id,
                    onTap: () => onChanged(profile.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BookProfileOptionRow extends StatelessWidget {
  const _BookProfileOptionRow({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    // Apple 设计系统：iOS 单选列表只在选中行尾画强调色对勾，未选中行留空
    // （透明对勾占位，行高与对齐不跳），不画 Material 的空心圆。
    final bool glass = !cupertino && isGlassDesign(context);
    final Color selectedColor = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : glass
        ? appleColorsOf(context).accent
        : Theme.of(context).colorScheme.primary;
    final Color idleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : glass
        ? Colors.transparent
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return AdaptiveSettingsRow(
      title: title,
      onTap: onTap,
      trailing: FushiIcon(
        selected
            ? (cupertino || glass
                  ? CupertinoIcons.check_mark
                  : Icons.radio_button_checked)
            : (cupertino
                  ? CupertinoIcons.circle
                  : glass
                  ? CupertinoIcons.check_mark
                  : Icons.radio_button_off),
        size: cupertino ? 20 : 22,
        color: selected ? selectedColor : idleColor,
      ),
    );
  }
}
