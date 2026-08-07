// GENERATED-NOTE: extracted from reader_fushi_history_page.dart (TODO-587).
part of '../reader_fushi_history_page.dart';

/// 书架删除确认弹窗。[onConfirm] 回传用户在「同步删除」勾选框选择的 [DeleteScope]
/// （勾选=[DeleteScope.syncEverywhere] 记墓碑传播到其他设备；默认不勾=
/// [DeleteScope.keepLocalOnly] 只删本机）。[showSyncScope]=false 时把勾选框换成
/// [DeleteScopeUnavailableNote] 说明行、恒 keepLocalOnly——由调用方按
/// `hasDeletionPropagationChannel` 传入：本机一个同步通道都没有时，那个勾选框兑现不了
/// （TODO-2470 死角②）。取消返回 null。
@visibleForTesting
class ReaderHistoryDeleteDialog extends StatefulWidget {
  const ReaderHistoryDeleteDialog({
    required this.title,
    required this.message,
    required this.onConfirm,
    this.showSyncScope = true,
    this.disclosure,
    super.key,
  });

  final String title;
  final String message;
  final ValueChanged<DeleteScope> onConfirm;
  final bool showSyncScope;

  /// 逐项披露真实删除范围；null 表示该入口暂未接入结构化披露。
  final DeletionDisclosure? disclosure;

  @override
  State<ReaderHistoryDeleteDialog> createState() =>
      _ReaderHistoryDeleteDialogState();
}

class _ReaderHistoryDeleteDialogState extends State<ReaderHistoryDeleteDialog> {
  bool _syncDelete = false;

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
              DeletionDisclosureView(disclosure: widget.disclosure!),
            ],
            SizedBox(height: tokens.spacing.gap),
            if (widget.showSyncScope)
              AdaptiveSettingsRow(
                title: t.delete_scope_sync_everywhere,
                subtitle: _syncDelete
                    ? t.delete_scope_sync_everywhere_desc
                    : t.delete_scope_keep_local_desc,
                onTap: () => setState(() => _syncDelete = !_syncDelete),
                trailing: Icon(
                  _syncDelete ? Icons.check_box : Icons.check_box_outline_blank,
                  color: _syncDelete
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            else
              const DeleteScopeUnavailableNote(),
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
              onPressed: () => widget.onConfirm(
                  widget.showSyncScope && _syncDelete
                      ? DeleteScope.syncEverywhere
                      : DeleteScope.keepLocalOnly),
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
    final int? current =
        await widget.profileRepo.getBookProfileId(widget.bookUid);

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
          child: TextButton(
            onPressed: onClose,
            child: Text(t.dialog_close),
          ),
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
    final Color selectedColor = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : Theme.of(context).colorScheme.primary;
    final Color idleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return AdaptiveSettingsRow(
      title: title,
      onTap: onTap,
      trailing: Icon(
        selected
            ? (cupertino
                ? CupertinoIcons.check_mark
                : Icons.radio_button_checked)
            : (cupertino ? CupertinoIcons.circle : Icons.radio_button_off),
        size: cupertino ? 20 : 22,
        color: selected ? selectedColor : idleColor,
      ),
    );
  }
}

class _BatchTagPickerDialog extends StatefulWidget {
  const _BatchTagPickerDialog({
    required this.allTags,
    required this.selectedKeys,
    required this.database,
    required this.parseBookKey,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedKeys;
  final FushiDatabase database;
  final String? Function(String) parseBookKey;

  @override
  State<_BatchTagPickerDialog> createState() => _BatchTagPickerDialogState();
}

class _BatchTagPickerDialogState extends State<_BatchTagPickerDialog> {
  final Set<int> _addTagIds = {};
  final Set<int> _removeTagIds = {};

  Future<void> _apply() async {
    final tr = Translations.of(context);
    final db = widget.database;

    final List<String> epubBookKeys = [];
    final List<String> srtUids = [];
    for (final key in widget.selectedKeys) {
      if (key.startsWith('srt_')) {
        srtUids.add(key.substring(4));
      } else {
        final String? bookKey = widget.parseBookKey(key);
        if (bookKey != null) epubBookKeys.add(bookKey);
      }
    }

    final List<int> srtBookIds = await _resolveSrtBookIds(srtUids);

    for (final tagId in _addTagIds) {
      for (final bookKey in epubBookKeys) {
        await db.addTagToBook(bookKey, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.addTagToSrtBook(srtId, tagId);
      }
    }
    for (final tagId in _removeTagIds) {
      for (final bookKey in epubBookKeys) {
        await db.removeTagFromBook(bookKey, tagId);
      }
      for (final srtId in srtBookIds) {
        await db.removeTagFromSrtBook(srtId, tagId);
      }
    }

    if (!mounted) return;
    for (final tagId in _addTagIds) {
      final tag = widget.allTags.firstWhere((row) => row.id == tagId);
      FushiToast.show(
        msg: tr.batch_tag_added(
          name: tag.name,
          n: widget.selectedKeys.length,
        ),
        severity: ToastSeverity.success,
      );
    }
    for (final tagId in _removeTagIds) {
      final tag = widget.allTags.firstWhere((row) => row.id == tagId);
      FushiToast.show(
        msg: tr.batch_tag_removed(
          name: tag.name,
          n: widget.selectedKeys.length,
        ),
        severity: ToastSeverity.success,
      );
    }
    Navigator.pop(context);
  }

  Future<List<int>> _resolveSrtBookIds(List<String> uids) async {
    final List<int> ids = [];
    final repo = SrtBookRepository(widget.database);
    for (final uid in uids) {
      final book = await repo.findByUid(uid);
      if (book?.id != null) ids.add(book!.id!);
    }
    return ids;
  }

  void _setTagIntent(BookTagRow tag, _BatchTagIntent intent) {
    setState(() {
      _addTagIds.remove(tag.id);
      _removeTagIds.remove(tag.id);
      switch (intent) {
        case _BatchTagIntent.keep:
          break;
        case _BatchTagIntent.add:
          _addTagIds.add(tag.id);
        case _BatchTagIntent.remove:
          _removeTagIds.add(tag.id);
      }
    });
  }

  _BatchTagIntent _tagIntent(BookTagRow tag) {
    if (_addTagIds.contains(tag.id)) return _BatchTagIntent.add;
    if (_removeTagIds.contains(tag.id)) return _BatchTagIntent.remove;
    return _BatchTagIntent.keep;
  }

  @override
  Widget build(BuildContext context) {
    return ReaderHistoryBatchTagDialogFrame(
      canApply: _addTagIds.isNotEmpty || _removeTagIds.isNotEmpty,
      onApply: _apply,
      body: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.allTags.length,
        itemBuilder: (_, i) {
          final tag = widget.allTags[i];
          return _BatchTagIntentRow(
            tag: tag,
            selected: _tagIntent(tag),
            onChanged: (intent) => _setTagIntent(tag, intent),
          );
        },
      ),
    );
  }
}

@visibleForTesting
class ReaderHistoryBatchTagDialogFrame extends StatelessWidget {
  const ReaderHistoryBatchTagDialogFrame({
    required this.body,
    required this.canApply,
    required this.onApply,
    super.key,
  });

  final Widget body;
  final bool canApply;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    // 与视频 tab 批量打标签弹窗共用 [BatchTagPickerDialogFrame] chrome；本壳保留为书架侧
    // 公开测试入口（reader_history_batch_tag_dialog_test 直接构造它验证紧凑窗口不溢出）。
    return BatchTagPickerDialogFrame(
      body: body,
      canApply: canApply,
      onApply: onApply,
    );
  }
}

enum _BatchTagIntent { keep, add, remove }

class _BatchTagIntentRow extends StatelessWidget {
  const _BatchTagIntentRow({
    required this.tag,
    required this.selected,
    required this.onChanged,
  });

  final BookTagRow tag;
  final _BatchTagIntent selected;
  final ValueChanged<_BatchTagIntent> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color tagColor = Color(tag.colorValue);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    // TODO-308: 三段意图原来用 keep=`horizontal_rule`、remove=`remove` 两个几乎
    // 一样的横杠（语义相反却长得一样），且纯图标无可见文字（tooltip 只有桌面悬停
    // 才出，手机/手柄看不到）。这里给每段配语义区分的图标 + 颜色 + 可见文字标签
    // （复用已有 i18n key），三段一眼可辨：
    //   keep   = 中性灰 圈内横杠（不改动）
    //   add    = 主色   实心加号圈（添加）
    //   remove = 错误红 禁止圈（移除，整段连文字一起染红）
    final Color removeColor = colors.error;
    final Color addColor = colors.primary;
    final Color keepColor = colors.onSurfaceVariant;

    Widget segmentLabel(String text, _BatchTagIntent intent, Color color) {
      // 三段共享一行、每段仅得 ~90dp（手机窄弹窗），双字标签必须锁死单行，
      // 否则 SegmentedButton 会把「保持」竖排成「保/持」（原缺陷）。softWrap
      // 关掉后文字一律横排；配合下方 Expanded 铺满行宽 + 收紧内边距保证放得下。
      return Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontSize: 12,
          color: selected == intent ? color : null,
        ),
      );
    }

    // 收紧每段横向内边距（默认 ~12dp/侧太宽，在窄弹窗里把 icon+双字挤到换行）。
    // 只在本弹窗局部覆盖，不动全局 kSettingsSegmentedStyle。
    final ButtonStyle segmentedStyle = kSettingsSegmentedStyle.copyWith(
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 6),
      ),
    );

    return AdaptiveSettingsRow(
      title: tag.name,
      icon: cupertino ? CupertinoIcons.tag : Icons.sell_outlined,
      controlBelow: true,
      // controlBelow 下 trailing 独占整行；用 Expanded 让三段铺满行宽（不再被
      // mainAxisSize.min + maxWidth:300 挤到 ~270 触发压缩换行）。
      trailing: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: tagColor,
              shape: BoxShape.circle,
            ),
            child: const SizedBox(width: 12, height: 12),
          ),
          SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
          Expanded(
            child: adaptiveSegmentedButton<_BatchTagIntent>(
              context: context,
              segments: [
                ButtonSegment<_BatchTagIntent>(
                  value: _BatchTagIntent.keep,
                  tooltip: t.batch_tag_keep,
                  label: segmentLabel(
                      t.batch_tag_keep, _BatchTagIntent.keep, keepColor),
                  icon: Icon(
                    cupertino
                        ? CupertinoIcons.minus_circle
                        : Icons.remove_circle_outline,
                    size: 16,
                    color: selected == _BatchTagIntent.keep ? keepColor : null,
                  ),
                ),
                ButtonSegment<_BatchTagIntent>(
                  value: _BatchTagIntent.add,
                  tooltip: t.batch_tag_add,
                  label: segmentLabel(
                      t.batch_tag_add, _BatchTagIntent.add, addColor),
                  icon: Icon(
                    cupertino ? CupertinoIcons.add_circled : Icons.add_circle,
                    size: 16,
                    color: selected == _BatchTagIntent.add ? addColor : null,
                  ),
                ),
                ButtonSegment<_BatchTagIntent>(
                  value: _BatchTagIntent.remove,
                  tooltip: t.batch_tag_remove,
                  label: segmentLabel(
                      t.batch_tag_remove, _BatchTagIntent.remove, removeColor),
                  icon: Icon(
                    cupertino
                        ? CupertinoIcons.minus_circle_fill
                        : Icons.do_not_disturb_on,
                    size: 16,
                    color:
                        selected == _BatchTagIntent.remove ? removeColor : null,
                  ),
                ),
              ],
              selected: {selected},
              onSelectionChanged: (values) {
                if (values.isNotEmpty) onChanged(values.first);
              },
              style: segmentedStyle,
            ),
          ),
        ],
      ),
    );
  }
}

/// TODO-308 测试钩子：渲染批量打标签的「保持 / 添加 / 移除」三段意图行，供 widget
/// 守卫断言三段各有可见文字标签与语义区分的图标（不再是两个一样的横杠）。
/// [selectedIndex] 0=keep / 1=add / 2=remove。
@visibleForTesting
Widget buildBatchTagIntentRowForTesting({
  required BookTagRow tag,
  int selectedIndex = 0,
}) {
  const List<_BatchTagIntent> intents = <_BatchTagIntent>[
    _BatchTagIntent.keep,
    _BatchTagIntent.add,
    _BatchTagIntent.remove,
  ];
  return _BatchTagIntentRow(
    tag: tag,
    selected: intents[selectedIndex],
    onChanged: (_) {},
  );
}
