import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

@visibleForTesting
class AudioSourcesDialog extends StatefulWidget {
  const AudioSourcesDialog({
    required this.sources,
    required this.onSave,
    this.onPickLocalDb,
    this.onEditLocalSources,
    super.key,
  });

  final List<AudioSourceConfig> sources;
  final void Function(List<AudioSourceConfig>) onSave;

  /// 选文件并导入为一个 localAudio 源（未持久化）；返回 null 表示用户取消。
  /// [reference]=true（仅桌面开关可启）时引用原文件不复制（BUG-483）。
  final Future<AudioSourceConfig?> Function(bool reference)? onPickLocalDb;

  /// 打开某个本地音频库的「子来源顺序 + 逐源启用」编辑器（按库路径）。
  final Future<void> Function(String path)? onEditLocalSources;

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
  /// 统一来源列表（hibikiRemote + remoteAudio + localAudio 混排，顺序即优先级）。
  late List<AudioSourceConfig> _sources;
  bool _importing = false;

  /// BUG-483：导入本地音频库时「引用原文件（不复制）」。仅桌面可见/可选；移动端
  /// file_picker 返回的是会被系统清掉的缓存临时副本，引用即指向消失的文件，恒 false。
  bool _referenceOriginal = false;
  bool _urlValid = false;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = List<AudioSourceConfig>.of(widget.sources);
  }

  @override
  void dispose() {
    // 任意关闭路径（底部「关闭」按钮 / 点遮罩 / 系统返回 / Esc）都落盘：本对话框没有
    // 「取消」概念（只有「重置」+「关闭」），用户心智=改了就生效。过去 onSave 只挂在
    // 底部「关闭」按钮上，点遮罩/返回会丢掉已导入的本地音频（且拷贝副本被 pruneOrphans
    // 回收）。把持久化下沉到 dispose 后，所有关闭路径行为一致（BUG-053）。
    widget.onSave(_sources);
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
          // 整体可滚动：列表 shrinkWrap + NeverScrollable，交由外层 SingleChildScrollView
          // 滚动；紧凑窗口下内容超高时整体滚动而非 RenderFlex 溢出。
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildSourceList(tokens),
                SizedBox(height: tokens.spacing.gap),
                _buildUrlField(tokens),
                if (widget.onPickLocalDb != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
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
                  // BUG-483：仅桌面暴露「引用原文件不复制」开关（移动端缓存副本不可引用）。
                  // 走共享 MD3 开关行（AdaptiveSettingsSwitchRow），不直接用
                  // 裸 SwitchListTile —— 否则触犯 md3 设计系统守卫且 chrome 不一致。
                  if (isDesktopPlatform)
                    AdaptiveSettingsSwitchRow(
                      icon: Icons.link_outlined,
                      title: t.local_audio_reference_original,
                      subtitle: t.local_audio_reference_original_desc,
                      value: _referenceOriginal,
                      onChanged: _importing
                          ? null
                          : (bool v) => setState(() => _referenceOriginal = v),
                    ),
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
              onPressed: _resetToDefaults,
              child: Text(t.reset),
            ),
            adaptiveDialogAction(
              context: context,
              // 持久化已下沉到 dispose（覆盖所有关闭路径，见 BUG-053），这里只负责出栈。
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }

  // ── 统一来源列表 ───────────────────────────────────────────────────────
  // 用自实现的 HibikiReorderableColumn（局部坐标长按拖拽），而非 SDK 的
  // ReorderableListView：后者的 Overlay 拖拽代理不认祖先 HibikiAppUiScale 的
  // Transform.scale，缩放界面下长按拖拽会飞出屏幕。前者把拖拽反馈渲染在列表自身坐标系、
  // 用 globalToLocal 消掉祖先缩放 → 任意缩放下都精确跟手、零偏移且视觉一致。
  // 上下箭头按钮仍是无障碍/手柄重排路径。
  Widget _buildSourceList(HibikiDesignTokens tokens) {
    return HibikiReorderableColumn(
      itemCount: _sources.length,
      keyForIndex: (int index) => ValueKey<String>(_sourceKeyId(index)),
      onReorder: (int from, int to) {
        setState(() {
          final AudioSourceConfig item = _sources.removeAt(from);
          _sources.insert(to, item);
        });
      },
      itemBuilder: (BuildContext context, int index) =>
          _buildSourceRow(tokens, index),
    );
  }

  /// 行身份 key（拖拽重排时稳定标识每一行）。
  String _sourceKeyId(int index) {
    final AudioSourceConfig source = _sources[index];
    return source.kind == AudioSourceKind.localAudio
        ? 'audio_local_${source.path ?? index}'
        : 'audio_remote_${source.kind.wireName}_${source.url ?? index}';
  }

  Widget _buildSourceRow(HibikiDesignTokens tokens, int index) {
    final AudioSourceConfig source = _sources[index];
    final bool isHibiki = source.kind == AudioSourceKind.hibikiRemote;
    final bool isLocal = source.kind == AudioSourceKind.localAudio;
    final String title =
        isHibiki ? t.audio_source_hibiki_interconnect : source.displayLabel;
    final String subtitle = isHibiki
        ? t.remote_audio_source
        : (isLocal ? (source.path ?? '') : (source.url ?? ''));
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: isLocal ? Icons.audiotrack_outlined : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 「调整子来源」只在本地库行出现；放在开关**左侧**，让开关/↑/↓/删除
          // 四列在所有行右贴边对齐（多出的 tune 只向左凸出，不挤动公共列）。
          if (isLocal &&
              widget.onEditLocalSources != null &&
              (source.path?.isNotEmpty ?? false))
            HibikiIconButton(
              icon: Icons.tune,
              size: 18,
              tooltip: t.local_audio_edit_sources,
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              onTap: () => widget.onEditLocalSources!(source.path!),
            ),
          Switch.adaptive(
            value: source.enabled,
            onChanged: (bool enabled) => setState(() {
              _sources[index] = source.copyWith(enabled: enabled);
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
              final AudioSourceConfig item = _sources.removeAt(index);
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
              final AudioSourceConfig item = _sources.removeAt(index);
              _sources.insert(index + 1, item);
            }),
          ),
          HibikiIconButton(
            icon: Icons.delete_outline,
            size: 18,
            tooltip: t.dialog_delete,
            enabled: !isHibiki,
            padding: EdgeInsets.all(tokens.spacing.gap / 2),
            onTap: () => setState(() => _sources.removeAt(index)),
          ),
        ],
      ),
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
              if (!_sources.any((AudioSourceConfig s) =>
                  s.kind == AudioSourceKind.hibikiRemote))
                HibikiIconButton(
                  icon: Icons.hub_outlined,
                  tooltip: t.audio_source_hibiki_interconnect,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: () => setState(() => _sources.insert(
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

  // ── actions ──────────────────────────────────────────────────────────────
  void _addRemoteUrl() {
    final String text = _controller.text.trim();
    if (!AudioSourcesDialog.isValidRemoteUrl(text)) {
      _showSnack(t.audio_source_url_invalid);
      return;
    }
    setState(() {
      _sources.insert(0, AudioSourceConfig.remoteAudio(url: text));
      _controller.clear();
      _urlValid = false;
    });
    _showSnack(t.audio_source_added);
  }

  Future<void> _addLocalDb() async {
    setState(() => _importing = true);
    try {
      final AudioSourceConfig? added =
          await widget.onPickLocalDb!(_referenceOriginal && isDesktopPlatform);
      if (!mounted) return;
      if (added != null) {
        setState(() => _sources.insert(0, added));
        // 导入即落盘：拷贝本地库是离散动作，当场持久化才让「导入成功」名副其实，
        // 且此后即便不经任何关闭路径退出（甚至杀进程）也不丢（BUG-053）；dispose
        // 的兜底保存仍覆盖此后的排序/开关/URL 等批量编辑。
        widget.onSave(_sources);
        _showSnack(t.local_audio_imported);
      }
      // added == null 表示用户取消选择，不弹反馈。
    } catch (e, st) {
      // BUG-446：原 `catch (_)` 整个吞掉异常对象，只弹通用文案，真因（PlatformException /
      // StateError / FileSystemException + errno）全丢。改为记完整诊断进 ErrorLogService
      // （错误日志页可查、可回传），并把异常类型摘要带进可见 snackbar，让用户能复述。
      ErrorLogService.instance.log('AudioSourcesDialog.addLocalDb', e, st);
      if (mounted) {
        _showSnack(t.local_audio_import_failed_detail(reason: '$e'));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _resetToDefaults() {
    setState(() {
      final bool hadHibiki = _sources
          .any((AudioSourceConfig s) => s.kind == AudioSourceKind.hibikiRemote);
      final List<AudioSourceConfig> locals = _sources
          .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
          .toList();
      _sources = <AudioSourceConfig>[
        if (hadHibiki) AudioSourceConfig.hibikiRemote(),
        ...AudioSourceConfig.fromLegacyUrls(AppModel.defaultAudioSources),
        ...locals,
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
