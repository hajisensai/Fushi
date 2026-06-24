import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/profile/profile_selector.dart';

/// Anki 设置正文（无脚手架）。直接平铺进「制卡」设置 destination 详情页
/// （见 `SettingsDestination.body`），不再藏在一层独立路由子页里。返回一个
/// [Column]，自身不带 `Scaffold` / 独立滚动——外层设置渲染器已提供滚动与内边距。
///
/// 末尾并入了原本挂在「制卡」分组里、与 Anki 子菜单并列的「自动添加书名到标签」
/// 开关，使整页就是完整的 Anki 配置入口。
///
/// 刻意用轻量 [ConsumerState]（而非 `BasePageState`）：`BasePageState.initState`
/// 会 `ref.read(creatorProvider)`，而本 body 现在会在设置 schema 覆盖率 harness
/// 里被直接渲染（不再藏在路由后），不引入 creator 依赖更稳。
class AnkiSettingsBody extends ConsumerStatefulWidget {
  const AnkiSettingsBody({super.key});

  @override
  ConsumerState<AnkiSettingsBody> createState() => _AnkiSettingsBodyState();
}

class _AnkiSettingsBodyState extends ConsumerState<AnkiSettingsBody> {
  AppModel get appModel => ref.watch(appProvider);
  ThemeData get theme => Theme.of(context);
  TextTheme get textTheme => theme.textTheme;

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(ankiViewModelProvider);
    final vm = ref.read(ankiViewModelProvider.notifier);
    final settings = uiState.settings;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsRow(
              title: t.profile_label,
              icon: Icons.person_outline,
              trailing: const ProfileSelector(),
            ),
            _buildFetchTile(uiState, vm),
            _buildCreateLapisTile(uiState, vm),
          ],
        ),
        if (!Platform.isAndroid)
          AdaptiveSettingsSection(
            title: 'AnkiConnect',
            children: [
              _AnkiConnectionField(
                label: t.anki_connect_host,
                value: settings.ankiConnectHost,
                hint: 'localhost',
                onChanged: vm.updateAnkiConnectHost,
              ),
              _AnkiConnectionField(
                label: t.anki_connect_port,
                value: settings.ankiConnectPort.toString(),
                hint: '8765',
                keyboardType: TextInputType.number,
                onChanged: vm.updateAnkiConnectPort,
              ),
              _AnkiConnectionField(
                label: t.anki_connect_api_key,
                value: settings.ankiConnectApiKey,
                hint: t.anki_connect_api_key_hint,
                onChanged: vm.updateAnkiConnectApiKey,
              ),
            ],
          ),
        if (uiState.errorMessage != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.gap + tokens.spacing.gap / 2,
              0,
              tokens.spacing.gap + tokens.spacing.gap / 2,
              tokens.spacing.gap + tokens.spacing.gap / 2,
            ),
            child: Text(
              uiState.errorMessage!,
              style:
                  textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        if (!uiState.isConfigured && uiState.errorMessage == null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.page + tokens.spacing.gap / 2,
            ),
            child: Text(
              t.anki_not_configured,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (uiState.isConfigured) ...[
          AdaptiveSettingsSection(
            children: [
              _buildDeckDropdown(settings, vm),
              _buildNoteTypeDropdown(settings, vm),
            ],
          ),
          AdaptiveSettingsSection(
            title: t.anki_field_mappings,
            children: _buildFieldMappings(settings, vm),
          ),
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsSwitchRow(
                title: t.anki_allow_duplicates,
                subtitle: t.anki_allow_duplicates_hint,
                value: settings.allowDupes,
                onChanged: vm.updateAllowDupes,
              ),
              // TODO-614：「覆写已制卡片」范围单选——和「允许重复」并排（两者都关乎
              // 「再点 ✓ 时改旧卡还是建新卡」）。latest=仅最近一张（默认=现状）；
              // all=按同一查重条件覆写任意已存在卡（含更早制的）。
              _buildOverwriteScopePicker(settings, vm),
              AdaptiveSettingsSwitchRow(
                title: t.anki_compact_glossaries,
                subtitle: t.anki_compact_glossaries_hint,
                value: settings.compactGlossaries,
                onChanged: vm.updateCompactGlossaries,
              ),
            ],
          ),
        ],
        // 默认标签区（TODO-135）：三个「自动给卡片加什么标签」的开关并到一处，
        // 且无条件显示——它们写的都是 pref（hibiki/分类写 AnkiSettings，书名写
        // AppModel.autoAddBookNameToTags），与 Anki 是否已连接无关，所以不再藏在
        // `uiState.isConfigured` 门控里。方案 A 的取舍：未配置 Anki 时 hibiki/分类
        // 两开关也会露出（用户已接受），换来三个语义同类的开关视觉聚在一起。
        // 标题/各开关 key 沿用 TODO-115/117 现有 i18n 与覆盖率 accounting 键。
        AdaptiveSettingsSection(
          title: t.anki_tag_default_section,
          children: [
            // TODO-614：自定义标签输入框归位到「默认标签」区最前——它和下面三个
            // 「自动加什么标签」开关同属「这张卡带哪些标签」，放一起更自洽。随该区
            // 无条件显示（未连 Anki 也露出，与同区两 tag 开关一致，取舍见上方注释）。
            _buildTagsInput(settings, vm),
            AdaptiveSettingsSwitchRow(
              title: t.anki_tag_include_hibiki,
              subtitle: t.anki_tag_include_hibiki_hint,
              value: settings.tagIncludeHibiki,
              onChanged: vm.updateTagIncludeHibiki,
            ),
            AdaptiveSettingsSwitchRow(
              title: t.anki_tag_include_category,
              subtitle: t.anki_tag_include_category_hint,
              value: settings.tagIncludeCategory,
              onChanged: vm.updateTagIncludeCategory,
            ),
            AdaptiveSettingsSwitchRow(
              title: t.auto_add_book_name_to_tags,
              icon: Icons.label_outline,
              value: appModel.autoAddBookNameToTags,
              onChanged: (bool value) {
                appModel.toggleAutoAddBookNameToTags();
                setState(() {});
              },
            ),
          ],
        ),
        // TODO-777 压缩制卡媒体开关：媒体压缩与「卡片带哪些标签」语义无关，单独占
        // 一个无标题区，紧随默认标签区之后。同样无条件显示（与标签区一致，不藏在
        // `uiState.isConfigured` 门控里）。默认开=压缩档（现状，省体积）；关闭走高
        // 保真档（音频立体声 128k / GIF 480px·12fps / 截图长边 2000px·质量 95），
        // 更清晰但卡片体积更大。
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsSwitchRow(
              title: t.compress_mining_media,
              subtitle: t.compress_mining_media_hint,
              icon: Icons.compress,
              value: appModel.compressMiningMedia,
              onChanged: (bool value) {
                appModel.toggleCompressMiningMedia();
                setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFetchTile(AnkiUiState uiState, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      icon: Icons.sync_outlined,
      showIcon: true,
      title: uiState.isFetching ? t.anki_fetching : t.anki_fetch,
      // Platform-neutral refresh hint (TODO-400): this row pulls the *current*
      // deck + note-type snapshot from Anki (AnkiConnect on desktop / iOS,
      // AnkiDroid on Android). The dropdowns only ever render what the last
      // fetch returned, so a deck created/renamed in Anki afterwards stays
      // invisible until the user taps here. The subtitle says exactly that,
      // replacing the old AnkiDroid-only "Fetch from AnkiDroid" label that made
      // desktop AnkiConnect users miss this as the refresh entry point.
      subtitle: uiState.isFetching ? null : t.anki_refresh_hint,
      // Action row, not navigation: a leading icon + state-layer ripple signals
      // tappability (MD3 list-item convention, same as SettingsActionItem); the
      // tap triggers a fetch (spinner while running) rather than opening a
      // subpage, so there is no trailing chevron.
      trailing: uiState.isFetching
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      onTap: uiState.isFetching ? null : () => vm.fetchConfiguration(),
    );
  }

  Widget _buildCreateLapisTile(AnkiUiState uiState, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      icon: Icons.note_add_outlined,
      showIcon: true,
      title: t.anki_create_lapis,
      subtitle: t.anki_create_lapis_hint,
      trailing: uiState.isFetching
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      onTap: uiState.isFetching ? null : () => _runCreateLapis(vm),
    );
  }

  Future<void> _runCreateLapis(AnkiViewModel vm) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await vm.createLapisSetup();
    if (!mounted) return;
    final String message;
    switch (result.outcome) {
      case LapisSetupOutcome.created:
        message = t.anki_create_lapis_success;
      case LapisSetupOutcome.alreadyExisted:
        message = t.anki_create_lapis_exists;
      case LapisSetupOutcome.failed:
        message = t.anki_create_lapis_failed(error: result.message ?? '');
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildDeckDropdown(AnkiSettings settings, AnkiViewModel vm) {
    final decks = settings.availableDecks;
    final selectedId = settings.selectedDeckId;
    final int? validSelectedId =
        decks.any((d) => d.id == selectedId) ? selectedId : null;

    return AdaptiveSettingsPickerRow<int?>(
      title: t.anki_deck,
      controlBelow: true,
      selected: validSelectedId,
      options: decks
          .map((d) => AdaptiveSettingsPickerOption<int?>(
                value: d.id,
                label: d.name,
              ))
          .toList(),
      onChanged: (id) {
        if (id == null) return;
        final deck = decks.firstWhere((d) => d.id == id);
        vm.selectDeck(deck);
      },
    );
  }

  Widget _buildNoteTypeDropdown(AnkiSettings settings, AnkiViewModel vm) {
    final noteTypes = settings.availableNoteTypes;
    final selectedId = settings.selectedNoteTypeId;
    final int? validSelectedId =
        noteTypes.any((n) => n.id == selectedId) ? selectedId : null;

    return AdaptiveSettingsPickerRow<int?>(
      title: t.anki_note_type,
      controlBelow: true,
      selected: validSelectedId,
      options: noteTypes
          .map((n) => AdaptiveSettingsPickerOption<int?>(
                value: n.id,
                label: n.name,
              ))
          .toList(),
      onChanged: (id) {
        if (id == null) return;
        final noteType = noteTypes.firstWhere((n) => n.id == id);
        vm.selectNoteType(noteType);
      },
    );
  }

  List<Widget> _buildFieldMappings(AnkiSettings settings, AnkiViewModel vm) {
    final noteType = settings.selectedNoteType;
    if (noteType == null) return const <Widget>[];

    return noteType.fields.map((field) {
      final value = settings.fieldMappings[field] ?? '';
      return AdaptiveSettingsNavigationRow(
        title: field,
        subtitle: value.isEmpty ? t.anki_field_not_mapped : value,
        icon: Icons.edit_outlined,
        onTap: () => _showHandlebarPicker(field, value, vm),
      );
    }).toList();
  }

  Future<void> _showHandlebarPicker(
    String field,
    String currentValue,
    AnkiViewModel vm,
  ) async {
    final dictionaryNames =
        appModel.termDictionaries.map((d) => d.name).toList();
    final options = AnkiHandlebarOptions.forTermDictionaries(dictionaryNames);

    final result = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AnkiHandlebarPickerDialog(
        title: t.anki_select_handlebar(field: field),
        initialValue: currentValue,
        options: options,
      ),
    );

    if (result != null) {
      vm.updateFieldMapping(field, result);
    }
  }

  Widget _buildTagsInput(AnkiSettings settings, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      title: t.anki_tags,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        initialValue: settings.tags,
        labelText: t.anki_tags,
        hintText: t.anki_tags_hint,
        onChanged: (v) => vm.updateTags(v),
      ),
    );
  }

  /// TODO-614：「覆写已制卡片」范围单选。latest=仅本会话最近一张（默认=现状）；
  /// all=按与查重同一条件（第一字段=expression）覆写任意已存在卡，使更早制的卡也
  /// 能在弹窗里点绿 ✓↩ 覆写。AnkiDroid 拿不到 note id → 选 all 仍降级为不可覆写
  /// 更早卡（与现状一致），不破坏现有行为。
  Widget _buildOverwriteScopePicker(AnkiSettings settings, AnkiViewModel vm) {
    return AdaptiveSettingsPickerRow<AnkiOverwriteScope>(
      title: t.anki_overwrite_scope,
      subtitle: t.anki_overwrite_scope_hint,
      controlBelow: true,
      selected: settings.overwriteScope,
      options: [
        AdaptiveSettingsPickerOption<AnkiOverwriteScope>(
          value: AnkiOverwriteScope.latest,
          label: t.anki_overwrite_scope_latest,
        ),
        AdaptiveSettingsPickerOption<AnkiOverwriteScope>(
          value: AnkiOverwriteScope.all,
          label: t.anki_overwrite_scope_all,
        ),
      ],
      onChanged: (scope) => vm.updateOverwriteScope(scope),
    );
  }
}

/// A single AnkiConnect connection setting (host / port / API key).
///
/// Persists on EVERY change via [onChanged] — not only on Enter — so tapping
/// "Fetch" right after typing uses the value the user just entered. It holds
/// its own [TextEditingController] (rather than a keyed `initialValue` field)
/// so it also reflects externally-loaded values (async settings load, profile
/// switch) without resetting the caret while the user is typing.
class _AnkiConnectionField extends StatefulWidget {
  const _AnkiConnectionField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.keyboardType = TextInputType.text,
  });

  final String label;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType keyboardType;

  @override
  State<_AnkiConnectionField> createState() => _AnkiConnectionFieldState();
}

class _AnkiConnectionFieldState extends State<_AnkiConnectionField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(_AnkiConnectionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect external value changes (async load, profile switch) ONLY while the
    // field is not being edited, so a lagging async save can never clobber the
    // user's in-progress typing.
    if (!_focusNode.hasFocus && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: widget.label,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: widget.keyboardType,
        hintText: widget.hint,
        onChanged: widget.onChanged,
      ),
    );
  }
}

@visibleForTesting
class AnkiHandlebarPickerDialog extends StatefulWidget {
  const AnkiHandlebarPickerDialog({
    required this.title,
    required this.initialValue,
    required this.options,
    super.key,
  });

  final String title;
  final String initialValue;
  final List<String> options;

  @override
  State<AnkiHandlebarPickerDialog> createState() =>
      _AnkiHandlebarPickerDialogState();
}

class _AnkiHandlebarPickerDialogState extends State<AnkiHandlebarPickerDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    // 弹窗整体高度只由外层 [HibikiDialogFrame.maxHeightFactor]（0.96）封顶：
    // sheet 不再叠加更紧的内层上限，由 [HibikiModalSheetFrame] 的 [Flexible] body
    // 在 DialogFrame 给的空间里自然填满并滚动（header / 搜索框 / footer 固定，选项
    // ListView 吃掉剩余高度）。早先这里用 `(height * 0.24).clamp(56, 320)` 的内层
    // ConstrainedBox 把整个 body（搜索框 + 十几~三十个选项的 ListView）死压在屏高
    // 24% / 封顶 320px——与外层 0.96 彻底矛盾，结果无论屏多大选项区永远只有一点点高
    // （800 高的设备上仅 ~192px），用户嫌「小得可怜」。现在去掉那个封顶后，选项区在
    // 高窗口能占大半屏；小窗口（如 320×240）下 body 是 Flexible 会收缩，header+搜索框
    // +footer 在 DialogFrame 的 0.96×height 上限内，不溢出。
    //
    // 注意：不要在 sheet 上设比 0.96 更小的 maxHeightFactor——那会在小窗口把 sheet
    // 夹得连 header+footer 都装不下而溢出（实测 240 高 + 0.82 factor → 196.8px 不够，
    // RenderFlex overflowed 20px）。
    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.96,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: widget.title,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          0,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveSettingsTextField(
              controller: _controller,
              hintText: t.anki_field_not_mapped,
            ),
            SizedBox(height: tokens.spacing.gap),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.options.length,
                itemBuilder: (_, i) {
                  final opt = widget.options[i];
                  if (opt == '-') return const Divider(height: 1);
                  final isSelected = widget.initialValue == opt;
                  return AdaptiveSettingsRow(
                    title: opt,
                    trailing: isSelected
                        ? Icon(
                            Icons.check,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.pop(context, opt),
                  );
                },
              ),
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
              onPressed: () => Navigator.pop(context, ''),
              child:
                  Text(MaterialLocalizations.of(context).deleteButtonTooltip),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, _controller.text),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
