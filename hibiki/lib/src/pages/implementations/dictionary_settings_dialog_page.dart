import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

@visibleForTesting
class AudioSourcesDialog extends StatefulWidget {
  const AudioSourcesDialog({
    required this.sources,
    required this.onSave,
    this.localAudioEnabled = false,
    this.onToggleLocalAudio,
    this.onPickLocalDb,
    super.key,
  });

  final List<AudioSourceConfig> sources;
  final void Function(List<AudioSourceConfig>) onSave;

  /// 本地音频全局总开关当前值（保留为对话框顶部的显式控件）。
  final bool localAudioEnabled;

  /// 切换全局总开关；立即生效（独立于 _sources 批量提交）。
  final Future<void> Function(bool enabled)? onToggleLocalAudio;

  /// 选文件并拷贝进库目录，返回一个 localAudio 源（已拷贝、未持久化）；
  /// 返回 null 表示用户取消。
  final Future<AudioSourceConfig?> Function()? onPickLocalDb;

  /// 自定义远端音频 URL 合法性：必须是 http(s) 链接，且至少含一个
  /// `{term}` / `{reading}` 占位符（否则播放时无法代入查词参数）。
  @visibleForTesting
  static bool isValidRemoteUrl(String text) {
    final String value = text.trim();
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return value.contains('{term}') || value.contains('{reading}');
  }

  @override
  State<AudioSourcesDialog> createState() => _AudioSourcesDialogState();
}

class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  /// 远端来源（hibikiRemote + remoteAudio），保留相对顺序、可拖拽。
  late List<AudioSourceConfig> _remoteSources;

  /// 本地音频源（localAudio），收纳在「本地音频」可展开分组里。
  late List<AudioSourceConfig> _localSources;

  late bool _localAudioEnabled;
  bool _localExpanded = false;
  bool _importing = false;
  bool _urlValid = false;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _remoteSources = widget.sources
        .where((AudioSourceConfig s) => s.kind != AudioSourceKind.localAudio)
        .toList();
    _localSources = widget.sources
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
        .toList();
    _localAudioEnabled = widget.localAudioEnabled;
    _localExpanded = widget.localAudioEnabled;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 关闭时回写的合并列表：所有远端源在前、本地源在后。
  List<AudioSourceConfig> get _combined =>
      <AudioSourceConfig>[..._remoteSources, ..._localSources];

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double maxHeight =
        (MediaQuery.of(context).size.height * 0.55).clamp(128.0, 420.0);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.manage_audio_sources,
        leadingIcon: Icons.graphic_eq_outlined,
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
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          // 整体可滚动：列表用 shrinkWrap + NeverScrollable 交由外层滚动，
          // 紧凑窗口下内容超高时整体滚动而非 RenderFlex 溢出。
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SettingsSectionHeader(t.audio_sources_remote_group),
                _buildRemoteList(tokens),
                SizedBox(height: tokens.spacing.gap),
                _buildUrlField(tokens),
                if (widget.onToggleLocalAudio != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  _buildLocalGroup(tokens),
                ],
              ],
            ),
          ),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: _resetRemoteToDefaults,
              child: Text(t.reset),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () {
                widget.onSave(_combined);
                Navigator.pop(context);
              },
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }

  // ── 远端来源分组 ────────────────────────────────────────────────────────
  Widget _buildRemoteList(HibikiDesignTokens tokens) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _remoteSources.length,
      onReorder: (int oldIndex, int newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final AudioSourceConfig item = _remoteSources.removeAt(oldIndex);
          _remoteSources.insert(newIndex, item);
        });
      },
      itemBuilder: (BuildContext context, int index) {
        final AudioSourceConfig source = _remoteSources[index];
        final bool isHibiki = source.kind == AudioSourceKind.hibikiRemote;
        return AdaptiveSettingsRow(
          key: ValueKey<String>(
            'audio_remote_${source.kind.wireName}_${source.url ?? index}',
          ),
          title: isHibiki
              ? t.audio_source_hibiki_interconnect
              : source.displayLabel,
          subtitle: isHibiki ? t.remote_audio_source : (source.url ?? ''),
          icon: Icons.drag_handle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Switch.adaptive(
                value: source.enabled,
                onChanged: (bool enabled) => setState(() {
                  _remoteSources[index] = source.copyWith(enabled: enabled);
                }),
              ),
              // Gamepad/keyboard reorder equivalent for the drag handle
              // (which a controller cannot grab).
              HibikiIconButton(
                icon: Icons.keyboard_arrow_up,
                size: 18,
                tooltip: t.move_up,
                enabled: index > 0,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => setState(() {
                  final AudioSourceConfig item = _remoteSources.removeAt(index);
                  _remoteSources.insert(index - 1, item);
                }),
              ),
              HibikiIconButton(
                icon: Icons.keyboard_arrow_down,
                size: 18,
                tooltip: t.move_down,
                enabled: index < _remoteSources.length - 1,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => setState(() {
                  final AudioSourceConfig item = _remoteSources.removeAt(index);
                  _remoteSources.insert(index + 1, item);
                }),
              ),
              HibikiIconButton(
                icon: Icons.delete_outline,
                size: 18,
                tooltip: t.dialog_delete,
                enabled: !isHibiki,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => setState(() => _remoteSources.removeAt(index)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildUrlField(HibikiDesignTokens tokens) {
    final bool showError = _controller.text.trim().isNotEmpty && !_urlValid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdaptiveSettingsTextField(
          controller: _controller,
          hintText: 'https://...{term}...{reading}',
          onChanged: (String value) => setState(
            () => _urlValid = AudioSourcesDialog.isValidRemoteUrl(value),
          ),
          onSubmitted: (_) => _addRemoteUrl(),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!_remoteSources.any((AudioSourceConfig s) =>
                  s.kind == AudioSourceKind.hibikiRemote))
                HibikiIconButton(
                  icon: Icons.hub_outlined,
                  tooltip: t.audio_source_hibiki_interconnect,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: () => setState(() => _remoteSources.insert(
                        0,
                        AudioSourceConfig.hibikiRemote(),
                      )),
                ),
              HibikiIconButton(
                icon: Icons.add,
                tooltip: t.dialog_add,
                enabled: _urlValid,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: _addRemoteUrl,
              ),
            ],
          ),
        ),
        if (showError)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
            child: Text(
              t.audio_source_url_invalid,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  // ── 本地音频分组（可展开） ─────────────────────────────────────────────
  Widget _buildLocalGroup(HibikiDesignTokens tokens) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.local_audio,
          icon: Icons.library_music_outlined,
          onTap: () => setState(() => _localExpanded = !_localExpanded),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Switch.adaptive(
                value: _localAudioEnabled,
                onChanged: (bool value) async {
                  await widget.onToggleLocalAudio!(value);
                  if (mounted) setState(() => _localAudioEnabled = value);
                },
              ),
              Icon(
                _localExpanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
            ],
          ),
        ),
        if (_localExpanded) ...<Widget>[
          if (_localSources.isNotEmpty)
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _localSources.length,
              itemBuilder: (BuildContext context, int index) {
                final AudioSourceConfig source = _localSources[index];
                return AdaptiveSettingsRow(
                  key: ValueKey<String>(
                    'audio_local_${source.path ?? index}',
                  ),
                  title: source.displayLabel,
                  subtitle: source.path ?? '',
                  icon: Icons.audiotrack_outlined,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Switch.adaptive(
                        value: source.enabled,
                        onChanged: (bool enabled) => setState(() {
                          _localSources[index] =
                              source.copyWith(enabled: enabled);
                        }),
                      ),
                      HibikiIconButton(
                        icon: Icons.delete_outline,
                        size: 18,
                        tooltip: t.dialog_delete,
                        padding: EdgeInsets.all(tokens.spacing.gap / 2),
                        onTap: () =>
                            setState(() => _localSources.removeAt(index)),
                      ),
                    ],
                  ),
                );
              },
            ),
          if (widget.onPickLocalDb != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: _importing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.library_add_outlined, size: 18),
                label: Text(t.local_audio_add_db),
                onPressed: _importing ? null : _addLocalDb,
              ),
            ),
        ],
      ],
    );
  }

  // ── actions ──────────────────────────────────────────────────────────────
  void _addRemoteUrl() {
    final String text = _controller.text.trim();
    if (!AudioSourcesDialog.isValidRemoteUrl(text)) {
      _showSnack(t.audio_source_url_invalid);
      return;
    }
    setState(() {
      _remoteSources.add(AudioSourceConfig.remoteAudio(url: text));
      _controller.clear();
      _urlValid = false;
    });
    _showSnack(t.audio_source_added);
  }

  Future<void> _addLocalDb() async {
    setState(() => _importing = true);
    try {
      final AudioSourceConfig? added = await widget.onPickLocalDb!();
      if (!mounted) return;
      if (added != null) {
        setState(() {
          _localSources.add(added);
          _localExpanded = true;
        });
        _showSnack(t.local_audio_imported);
      }
      // added == null 表示用户取消选择，不弹反馈。
    } catch (_) {
      if (mounted) _showSnack(t.local_audio_import_failed);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _resetRemoteToDefaults() {
    setState(() {
      final bool hadHibiki = _remoteSources
          .any((AudioSourceConfig s) => s.kind == AudioSourceKind.hibikiRemote);
      _remoteSources = <AudioSourceConfig>[
        if (hadHibiki) AudioSourceConfig.hibikiRemote(),
        ...AudioSourceConfig.fromLegacyUrls(AppModel.defaultAudioSources),
      ];
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class DictCssEditorDialog extends StatefulWidget {
  const DictCssEditorDialog({
    super.key,
    this.initialDictionaryName,
  });

  final String? initialDictionaryName;

  @override
  State<DictCssEditorDialog> createState() => _DictCssEditorDialogState();
}

class _DictCssEditorDialogState extends State<DictCssEditorDialog> {
  late int _selectedIndex;
  late TextEditingController _cssController;
  late List<String> _dictNames;
  late AppModel _appModel;

  bool get _isGlobal => _selectedIndex == 0;
  String get _currentDictName => _dictNames[_selectedIndex - 1];

  @override
  void initState() {
    super.initState();
    _appModel =
        ProviderScope.containerOf(context, listen: false).read(appProvider);
    _dictNames = _appModel.dictionaries.map((d) => d.name).toList();
    _selectedIndex = _initialSelectedIndex();
    _cssController = TextEditingController(text: _currentCss);
  }

  @override
  void dispose() {
    _cssController.dispose();
    super.dispose();
  }

  Future<void> _onScopeChanged(int? index) async {
    if (index == null || index == _selectedIndex) return;
    await _saveCurrentScope();
    _selectedIndex = index;
    _cssController.text = _currentCss;
    setState(() {});
  }

  Future<void> _saveCurrentScope() async {
    final css = _cssController.text;
    if (_isGlobal) {
      await _appModel.setGlobalDictCSS(css);
    } else {
      await _appModel.setCustomCSSForDict(_currentDictName, css);
    }
  }

  int _initialSelectedIndex() {
    final String? initialDictionaryName = widget.initialDictionaryName;
    if (initialDictionaryName == null) return 0;
    final int dictIndex = _dictNames.indexOf(initialDictionaryName);
    return dictIndex < 0 ? 0 : dictIndex + 1;
  }

  String get _currentCss {
    return _isGlobal
        ? _appModel.globalDictCSS
        : _appModel.getCustomCSSForDict(_currentDictName);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Size mediaSize = MediaQuery.of(context).size;
    final double contentHeight = (mediaSize.height * 0.55).clamp(280.0, 480.0);

    return HibikiDialogFrame(
      maxWidth: 640,
      maxHeightFactor: 0.88,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.custom_dict_css,
        leadingIcon: Icons.code_outlined,
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
        body: SizedBox(
          width: double.maxFinite,
          height: contentHeight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildScopeDropdown(context),
              SizedBox(height: tokens.spacing.gap),
              Expanded(
                child: HibikiEditorPanel(
                  controller: _cssController,
                ),
              ),
            ],
          ),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              child: Text(t.dialog_close),
              onPressed: () async {
                await _saveCurrentScope();
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScopeDropdown(BuildContext context) {
    return GamepadMenuDropdown<int>(
      width: double.infinity,
      label: t.custom_dict_css,
      selected: _selectedIndex,
      onChanged: _onScopeChanged,
      entries: <GamepadDropdownEntry<int>>[
        (value: 0, label: t.custom_dict_css_global),
        for (int i = 0; i < _dictNames.length; i++)
          (value: i + 1, label: _dictNames[i]),
      ],
    );
  }
}
