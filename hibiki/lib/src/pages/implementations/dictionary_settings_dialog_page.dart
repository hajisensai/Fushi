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

  @override
  State<AudioSourcesDialog> createState() => _AudioSourcesDialogState();
}

class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  late List<AudioSourceConfig> _sources;
  late bool _localAudioEnabled;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = List<AudioSourceConfig>.from(widget.sources);
    _localAudioEnabled = widget.localAudioEnabled;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onToggleLocalAudio != null) ...<Widget>[
                AdaptiveSettingsRow(
                  title: t.local_audio,
                  icon: Icons.library_music_outlined,
                  trailing: Switch.adaptive(
                    value: _localAudioEnabled,
                    onChanged: (bool value) async {
                      await widget.onToggleLocalAudio!(value);
                      if (mounted) setState(() => _localAudioEnabled = value);
                    },
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
              ],
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  itemCount: _sources.length,
                  onReorder: (int oldIndex, int newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex--;
                      final item = _sources.removeAt(oldIndex);
                      _sources.insert(newIndex, item);
                    });
                  },
                  itemBuilder: (context, index) {
                    final AudioSourceConfig source = _sources[index];
                    return AdaptiveSettingsRow(
                      key: ValueKey(
                        'audio_src_${source.kind.wireName}_${source.url ?? source.path ?? index}',
                      ),
                      title: source.displayLabel,
                      subtitle: _sourceSubtitle(source),
                      icon: Icons.drag_handle,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch.adaptive(
                            value: source.enabled,
                            onChanged: (bool enabled) => setState(() {
                              _sources[index] =
                                  source.copyWith(enabled: enabled);
                            }),
                          ),
                          // Gamepad/keyboard reorder equivalent for the
                          // drag handle (which a controller cannot grab).
                          HibikiIconButton(
                            icon: Icons.keyboard_arrow_up,
                            size: 18,
                            tooltip: t.move_up,
                            enabled: index > 0,
                            padding: EdgeInsets.all(tokens.spacing.gap / 2),
                            onTap: () => setState(() {
                              final item = _sources.removeAt(index);
                              _sources.insert(index - 1, item);
                            }),
                          ),
                          HibikiIconButton(
                            icon: Icons.keyboard_arrow_down,
                            size: 18,
                            tooltip: t.move_down,
                            enabled: index < _sources.length - 1,
                            padding: EdgeInsets.all(tokens.spacing.gap / 2),
                            onTap: () => setState(() {
                              final item = _sources.removeAt(index);
                              _sources.insert(index + 1, item);
                            }),
                          ),
                          HibikiIconButton(
                            icon: Icons.delete_outline,
                            size: 18,
                            tooltip: t.dialog_delete,
                            enabled:
                                source.kind != AudioSourceKind.hibikiRemote,
                            padding: EdgeInsets.all(tokens.spacing.gap / 2),
                            onTap: () {
                              setState(() {
                                _sources.removeAt(index);
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
              AdaptiveSettingsTextField(
                controller: _controller,
                hintText: 'https://...{term}...{reading}',
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_sources.any((AudioSourceConfig source) =>
                        source.kind == AudioSourceKind.hibikiRemote))
                      HibikiIconButton(
                        icon: Icons.hub_outlined,
                        tooltip: t.remote_audio_source,
                        padding: EdgeInsets.all(tokens.spacing.gap / 2),
                        onTap: () => setState(() {
                          _sources.insert(
                            0,
                            AudioSourceConfig.hibikiRemote(),
                          );
                        }),
                      ),
                    HibikiIconButton(
                      icon: Icons.add,
                      tooltip: t.dialog_add,
                      padding: EdgeInsets.all(tokens.spacing.gap / 2),
                      onTap: _addSource,
                    ),
                  ],
                ),
                onSubmitted: (_) => _addSource(),
              ),
              if (widget.onPickLocalDb != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.library_add_outlined, size: 18),
                    label: Text(t.local_audio_add_db),
                    onPressed: () async {
                      final AudioSourceConfig? added =
                          await widget.onPickLocalDb!();
                      if (added != null && mounted) {
                        setState(() => _sources.add(added));
                      }
                    },
                  ),
                ),
              ],
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
              onPressed: () {
                setState(() {
                  final List<AudioSourceConfig> kept = _sources
                      .where((AudioSourceConfig s) =>
                          s.kind != AudioSourceKind.remoteAudio)
                      .toList();
                  _sources = <AudioSourceConfig>[
                    ...kept,
                    ...AudioSourceConfig.fromLegacyUrls(
                      AppModel.defaultAudioSources,
                    ),
                  ];
                });
              },
              child: Text(t.reset),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () {
                widget.onSave(_sources);
                Navigator.pop(context);
              },
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }

  void _addSource() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      setState(() {
        _sources.add(AudioSourceConfig.remoteAudio(url: text));
        _controller.clear();
      });
    }
  }

  String _sourceSubtitle(AudioSourceConfig source) {
    switch (source.kind) {
      case AudioSourceKind.hibikiRemote:
        return t.remote_audio_source;
      case AudioSourceKind.localAudio:
        return t.local_audio;
      case AudioSourceKind.remoteAudio:
        return source.url ?? '';
    }
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
