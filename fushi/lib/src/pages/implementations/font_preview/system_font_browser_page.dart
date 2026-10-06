import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_specimen.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_target_preview.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';
import 'package:fushi/src/reader/reader_settings.dart' show FontTarget;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 按搜索词与日文筛选过滤系统字体。`supportsJapanese == null`（该平台判不出）
/// 的字体不被日文筛选排除——判不出不等于不支持。
List<SystemFontFamily> filterSystemFontFamilies(
  List<SystemFontFamily> families, {
  required String query,
  required bool japaneseOnly,
}) {
  final List<SystemFontFamily> byJapanese = japaneseOnly
      ? families
            .where((SystemFontFamily f) => f.supportsJapanese != false)
            .toList()
      : families;
  return filterByMediaSearch(
    byJapanese,
    query,
    (SystemFontFamily f) => <String>[f.family],
  );
}

/// 「添加系统字体」浏览页：每款系统字体都用它自己渲染名字与日文样字，点一下
/// 在底部的用途样张里试用，勾选后一次加入字体库。
///
/// 返回选中的族名列表（取消为 null）。只读系统字体清单、不写任何偏好——
/// 加入字体库与挂用途由调用方（字体库页）完成。
class SystemFontBrowserPage extends StatefulWidget {
  const SystemFontBrowserPage({
    required this.alreadyAdded,
    required this.target,
    super.key,
  });

  /// 字体库里已有的名字（大小写不敏感比较），不可再选。
  final Set<String> alreadyAdded;

  /// 从哪个用途进来：底部样张按它的形态渲染。
  final FontTarget target;

  @override
  State<SystemFontBrowserPage> createState() => _SystemFontBrowserPageState();
}

class _SystemFontBrowserPageState extends State<SystemFontBrowserPage> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _sampleController = TextEditingController();

  SystemFontList _list = SystemFontList.empty;
  bool _loading = true;
  bool _japaneseOnly = true;

  /// 已勾选、待加入的族名（保持勾选顺序）。
  final List<String> _selected = <String>[];

  /// 底部样张正在试用的族名。
  String? _previewFamily;

  late final Set<String> _addedKeys = <String>{
    for (final String name in widget.alreadyAdded) name.toLowerCase(),
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final SystemFontList list = await SystemFontCatalog.load();
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _sampleController.dispose();
    super.dispose();
  }

  bool get _hasJapaneseInfo =>
      _list.families.any((SystemFontFamily f) => f.supportsJapanese != null);

  bool _isAdded(String family) => _addedKeys.contains(family.toLowerCase());

  void _toggle(String family) {
    setState(() {
      _previewFamily = family;
      if (!_selected.remove(family)) _selected.add(family);
    });
  }

  String? get _sampleOverride {
    final String text = _sampleController.text.trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<SystemFontFamily> visible = filterSystemFontFamilies(
      _list.families,
      query: _searchController.text,
      japaneseOnly: _japaneseOnly && _hasJapaneseInfo,
    );
    final String glyphs = _sampleOverride ?? kJaFontSpecimenGlyphs;

    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSearchBar(
            fieldKey: const ValueKey<String>('system-font-search'),
            controller: _searchController,
            hintText: t.custom_fonts_search_hint,
            onQueryChanged: (_) => setState(() {}),
          ),
          SizedBox(height: tokens.spacing.gap),
          FushiTextField(
            key: const ValueKey<String>('system-font-sample'),
            controller: _sampleController,
            hintText: t.font_preview_sample_text,
            prefixIcon: const FushiIcon(FushiIcons.textFields),
            contentPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_hasJapaneseInfo) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiSelectableChip(
                key: const ValueKey<String>('system-font-japanese-only'),
                label: t.custom_fonts_system_japanese_only,
                leadingIcon: FushiIcons.language,
                selected: _japaneseOnly,
                onSelected: (bool value) =>
                    setState(() => _japaneseOnly = value),
              ),
            ),
          ],
          if (!_list.namesReliable) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            // 「名称是近似值」是提醒不是错误：走共享提示块（警告图标），
            // 不再是整行红字。
            FushiInlineNotice(
              severity: FushiNoticeSeverity.warning,
              message: t.custom_fonts_system_names_approximate,
            ),
          ],
          SizedBox(height: tokens.spacing.gap),
        ],
      ),
    );

    final Widget list = _loading
        ? const FushiLoadingView()
        : visible.isEmpty
        ? Center(
            child: FushiPlaceholderMessage(
              icon: FushiIcons.font,
              message: t.custom_fonts_empty,
            ),
          )
        // M3E 分段卡片列表（首尾大圆角、行间 2）+ 首屏错峰进场。
        : FushiEntranceScope(
            child: ListView.builder(
              key: const ValueKey<String>('system-font-list'),
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              itemCount: visible.length,
              itemBuilder: (BuildContext context, int index) {
                final SystemFontFamily font = visible[index];
                final bool added = _isAdded(font.family);
                final bool selected = _selected.contains(font.family);
                return FushiStaggeredEntrance(
                  index: index,
                  child: FushiGroupedListItem(
                    index: index,
                    count: visible.length,
                    child: FushiListItem(
                      key: ValueKey<String>('system-font-${font.family}'),
                      selected: selected || _previewFamily == font.family,
                      onTap: added ? null : () => _toggle(font.family),
                      title: FontSpecimenLine(
                        label: font.family,
                        family: font.family,
                        glyphs: glyphs,
                        selected: selected,
                      ),
                      subtitle: font.supportsJapanese == true
                          ? Text(
                              t.custom_fonts_system_supports_japanese,
                              style: tokens.type.metadata.copyWith(
                                color: scheme.primary,
                              ),
                            )
                          : null,
                      trailing: added
                          ? FushiIcon(FushiIcons.check, color: scheme.outline)
                          : FushiCheckbox(
                              value: selected,
                              onChanged: (_) => _toggle(font.family),
                            ),
                    ),
                  ),
                );
              },
            ),
          );

    final String? previewFamily = _previewFamily;
    // 底部预览面板：MD3 = group 底 + 2 级抬升；Apple = 无投影、顶部一条
    // separator 发丝线（iOS 底部工具区的分隔方式）。只换参数，不增删包装层。
    final bool glass = isGlassDesign(context);
    final Widget bottomPanel = Material(
      color: glass
          ? appleColorsOf(context).secondaryGroupedBackground
          : tokens.surfaces.group,
      elevation: glass ? 0 : 2,
      // M3E 底部面板：上两角 28（与底部弹层同一大容器形状）。
      shape: glass
          ? Border(
              top: BorderSide(
                color: appleColorsOf(context).separator,
                width: 0.5,
              ),
            )
          : const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${t.font_preview_title} · '
                      '${previewFamily ?? t.font_preview_default_font}',
                      style: tokens.type.sectionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FushiFilledButton.icon(
                    key: const ValueKey<String>('system-font-add'),
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            List<String>.of(_selected),
                          ),
                    icon: const FushiIcon(FushiIcons.add),
                    label: Text(
                      t.custom_fonts_system_add_count(count: _selected.length),
                    ),
                  ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: FontTargetPreview(
                    target: widget.target,
                    families: previewFamily == null
                        ? const <String>[]
                        : <String>[previewFamily],
                    sampleText: _sampleOverride,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return FushiToolScaffold(
      title: t.custom_fonts_add_system,
      actions: <Widget>[
        if (_selected.isNotEmpty)
          FushiIconButton(
            icon: FushiIcons.deleteSweep,
            tooltip: t.dialog_cancel,
            onTap: () => setState(_selected.clear),
          ),
      ],
      bottomNavigationBar: bottomPanel,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,
          Expanded(child: list),
        ],
      ),
    );
  }
}
