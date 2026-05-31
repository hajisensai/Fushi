import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

@visibleForTesting
class AudioSourcesDialog extends StatefulWidget {
  const AudioSourcesDialog({
    required this.sources,
    required this.onSave,
    super.key,
  });

  final List<String> sources;
  final void Function(List<String>) onSave;

  @override
  State<AudioSourcesDialog> createState() => _AudioSourcesDialogState();
}

class _AudioSourcesDialogState extends State<AudioSourcesDialog> {
  late List<String> _sources;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = List<String>.from(widget.sources);
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
        (MediaQuery.of(context).size.height * 0.24).clamp(56.0, 320.0);

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
                    return AdaptiveSettingsRow(
                      key: ValueKey('audio_src_$index'),
                      title: _sources[index],
                      icon: Icons.drag_handle,
                      trailing: HibikiIconButton(
                        icon: Icons.delete_outline,
                        size: 18,
                        tooltip: t.dialog_delete,
                        padding: EdgeInsets.all(tokens.spacing.gap / 2),
                        onTap: () {
                          setState(() {
                            _sources.removeAt(index);
                          });
                        },
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
              AdaptiveSettingsTextField(
                controller: _controller,
                hintText: 'https://...{term}...{reading}',
                suffixIcon: HibikiIconButton(
                  icon: Icons.add,
                  tooltip: t.dialog_add,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: _addSource,
                ),
                onSubmitted: (_) => _addSource(),
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
              onPressed: () {
                setState(() {
                  _sources = List<String>.from(AppModel.defaultAudioSources);
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
        _sources.add(text);
        _controller.clear();
      });
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
