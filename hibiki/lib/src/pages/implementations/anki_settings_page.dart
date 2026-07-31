import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_media_dedup_dialogs.dart';
import 'package:hibiki/src/anki/lapis_backup_retention.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/anki/lapis_template_service.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart'
    show VideoMiningImageMode;
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

  /// 「创建 Lapis 卡组」在途标记（UI 层，独立于 vm 的 isFetching）。vm 的
  /// createLapisSetup 内部复用 isFetching，若两行 spinner 都读它，点 Lapis 时
  /// 「刷新」行也会转圈——各行只对自己的动作显示 busy。
  bool _creatingLapis = false;

  /// Lapis 样式区（备份/恢复/应用）在途标记：这几个动作都写同一个 note
  /// type，互斥防重入。
  bool _lapisBusy = false;

  /// 媒体去重在途标记（扫描/执行互斥防重入）。
  bool _dedupBusy = false;

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
            // showIcon 与同卡片的刷新/Lapis 行一致，左栏图标对齐。
            AdaptiveSettingsRow(
              title: t.profile_label,
              icon: Icons.person_outline,
              showIcon: true,
              trailing: const ProfileSelector(),
            ),
            _buildFetchTile(uiState, vm),
            _buildCreateLapisTile(uiState, vm),
          ],
        ),
        // NOTE:「制卡到已配对设备」开关已移到设置 →「Hibiki 互联」→「交给已配对设备」
        // （见 buildInterconnectDestination）。它的前置条件、目标主机、失效条件全部由互联
        // 决定（未启用互联/未配对时只会让制卡失败），留在这里是一个与本页其余 Anki 本地
        // 配置无关、且在互联关闭时纯死的开关。
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
        // Lapis 样式客制化：备份 / 恢复 / 字号缩放 / 自定义 CSS / 应用。
        // 仅后端支持读写已存在 note type 时显示（AnkiConnect）；AnkiDroid /
        // AnkiMobile 平台 API 改不了已存在模板（平台边界），整区隐藏。
        if (vm.supportsNoteTypeEditing)
          AdaptiveSettingsSection(
            title: t.anki_lapis_section,
            children: [
              AdaptiveSettingsPickerRow<int>(
                title: t.anki_lapis_font_scale,
                subtitle: t.anki_lapis_font_scale_hint,
                icon: Icons.format_size_outlined,
                showIcon: true,
                selected: settings.lapisFontScalePercent,
                // 档位表来自 hibiki_anki 的单一真相源：从备份恢复时
                // splitLapisUserSectionBody 会优先反解出这些档位，选择器与
                // 反解各写一份迟早漂成「显示了一个档位表里没有的值」。
                options: <AdaptiveSettingsPickerOption<int>>[
                  for (final int p in kLapisFontScalePresets)
                    AdaptiveSettingsPickerOption<int>(value: p, label: '$p%'),
                ],
                onChanged: (int v) => vm.setLapisFontScalePercent(v),
              ),
              AdaptiveSettingsRow(
                icon: Icons.code_outlined,
                showIcon: true,
                title: t.anki_lapis_custom_css,
                subtitle: t.anki_lapis_custom_css_hint,
                onTap: () => _editLapisCustomCss(settings, vm),
              ),
              AdaptiveSettingsRow(
                icon: Icons.brush_outlined,
                showIcon: true,
                title: t.anki_lapis_apply,
                trailing: _lapisBusy
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child:
                            adaptiveIndicator(context: context, strokeWidth: 2),
                      )
                    : null,
                onTap: _lapisBusy ? null : () => _applyLapisStyling(vm),
              ),
              AdaptiveSettingsRow(
                icon: Icons.save_outlined,
                showIcon: true,
                title: t.anki_lapis_backup,
                onTap: _lapisBusy ? null : () => _backupLapisTemplate(vm),
              ),
              AdaptiveSettingsRow(
                icon: Icons.settings_backup_restore_outlined,
                showIcon: true,
                title: t.anki_lapis_restore,
                onTap: _lapisBusy ? null : () => _restoreLapisBackup(vm),
              ),
            ],
          ),
        // 媒体存储优化：字节级去重（只删字节相同的多余副本，绝不重编码）。
        // 需要与 Anki 同机（本机可直读 collection.media），后端不支持时整区隐藏。
        // 用户拍板方案 A：默认不跑；自动处理是一个**默认关**的开关，打开之后
        // 也只是自动干跑并提示，真删仍要用户确认——除非再显式打开「自动直接
        // 删除」。手动触发同样先看干跑清单再确认。
        if (vm.supportsMediaMaintenance)
          AdaptiveSettingsSection(
            title: t.anki_dedup_section,
            children: [
              AdaptiveSettingsSwitchRow(
                icon: Icons.autorenew_outlined,
                showIcon: true,
                title: t.anki_dedup_auto,
                subtitle: t.anki_dedup_auto_hint,
                value: settings.mediaDedupAutoEnabled,
                onChanged: (bool v) => vm.setMediaDedupAutoEnabled(v),
              ),
              // 从属开关：自动处理关着的时候它无意义，置灰而不是隐藏——隐藏
              // 会让用户以为「打开自动 = 直接删」。
              AdaptiveSettingsSwitchRow(
                icon: Icons.delete_forever_outlined,
                showIcon: true,
                title: t.anki_dedup_auto_delete,
                subtitle: t.anki_dedup_auto_delete_hint,
                value: settings.mediaDedupAutoDelete,
                onChanged: settings.mediaDedupAutoEnabled
                    ? (bool v) => vm.setMediaDedupAutoDelete(v)
                    : null,
              ),
              AdaptiveSettingsRow(
                icon: Icons.search_outlined,
                showIcon: true,
                title: t.anki_dedup_scan,
                trailing: _dedupBusy
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child:
                            adaptiveIndicator(context: context, strokeWidth: 2),
                      )
                    : null,
                onTap: _dedupBusy ? null : () => _scanMediaDedup(vm),
              ),
              AdaptiveSettingsRow(
                icon: Icons.cleaning_services_outlined,
                showIcon: true,
                title: t.anki_dedup_run,
                subtitle: t.anki_dedup_run_hint,
                onTap: _dedupBusy ? null : () => _runMediaDedup(vm),
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
              // 查重范围：与「允许重复」「覆写范围」同区（三者都关乎「这个词算不算
              // 已经有卡、再点 ✓ 时怎么办」）。默认 deck = 旧行为。
              _buildDuplicateScopePicker(settings, vm),
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
        // TODO-1650 制卡媒体清晰度：媒体清晰度与「卡片带哪些标签」语义无关，单独占
        // 一个无标题区，紧随默认标签区之后。无条件显示（与标签区一致，不藏在
        // `uiState.isConfigured` 门控里）。图片/GIF 清晰度与音频质量各是一个独立滑块
        // （替代旧的单一「压缩」开关）：越高越清晰、体积越大；满档=最高（截图原图直通，
        // GIF 封顶——BUG-1039）。
        AdaptiveSettingsSection(
          children: [
            _buildMiningImageQualityRow(),
            _buildMiningAudioQualityRow(),
            _buildVideoMiningImageModePicker(),
            _buildGalMiningImageModePicker(),
          ],
        ),
      ],
    );
  }

  /// TODO-1650 图片/GIF 清晰度滑块（4 档 0..3，透传 [AppModel.miningImageQuality]）。
  /// 只管截图分辨率/质量 + GIF 帧率/宽度；满档=最高（截图原图直通，GIF 封顶）。滑块值即档位下标，
  /// `divisions/step=1` 让它按档吸附，`readout`/`label` 显示当前档名。
  Widget _buildMiningImageQualityRow() {
    final List<String> labels = <String>[
      t.mining_image_quality_thrift,
      t.mining_image_quality_standard,
      t.mining_image_quality_hd,
      // BUG-1039：满档过去叫「原片」，但它对 GIF 已不是源分辨率/源帧率（见
      // [MiningMediaCompression.imageTiers]），只有截图仍是原图直通——名不副实，
      // 改叫「最高」：只承诺是滑块顶格，不承诺具体保真度。
      t.mining_image_quality_max,
    ];
    final int tier = appModel.miningImageQuality.clamp(0, labels.length - 1);
    return AdaptiveSettingsSliderRow(
      title: t.mining_image_quality,
      subtitle: t.mining_image_quality_hint,
      icon: Icons.hd_outlined,
      value: tier.toDouble(),
      min: 0,
      max: (labels.length - 1).toDouble(),
      divisions: labels.length - 1,
      step: 1,
      label: labels[tier],
      readout: labels[tier],
      onChanged: (double value) {
        appModel.setMiningImageQuality(value.round());
        setState(() {});
      },
    );
  }

  /// TODO-1650 音频质量滑块（3 档 0..2，透传 [AppModel.miningAudioQuality]）。只管句子/cue
  /// 音频声道 + 比特率；满档=最高（立体声 192k）。
  Widget _buildMiningAudioQualityRow() {
    final List<String> labels = <String>[
      t.mining_audio_quality_standard,
      t.mining_audio_quality_high,
      // BUG-1039：满档过去也叫「原片」，但 192k 立体声 AAC 是有损重编码、不是原片；
      // 与图片滑块统一改叫「最高」（只承诺是滑块顶格）。
      t.mining_audio_quality_max,
    ];
    final int tier = appModel.miningAudioQuality.clamp(0, labels.length - 1);
    return AdaptiveSettingsSliderRow(
      title: t.mining_audio_quality,
      subtitle: t.mining_audio_quality_hint,
      icon: Icons.graphic_eq,
      value: tier.toDouble(),
      min: 0,
      max: (labels.length - 1).toDouble(),
      divisions: labels.length - 1,
      step: 1,
      label: labels[tier],
      readout: labels[tier],
      onChanged: (double value) {
        appModel.setMiningAudioQuality(value.round());
        setState(() {});
      },
    );
  }

  /// 视频制卡封面图片模式三选一：gif=字幕区间动图（默认，现状零破坏）；currentFrame=
  /// 制卡那一刻的当前解码帧（点词已自动暂停）；subtitleStart=当前字幕 cue 起始时间点的帧。
  /// 全局设置，透传 [AppModel.videoMiningImageMode]，所有视频制卡生效。
  Widget _buildVideoMiningImageModePicker() {
    return AdaptiveSettingsPickerRow<VideoMiningImageMode>(
      title: t.video_mining_image_mode,
      subtitle: t.video_mining_image_mode_hint,
      icon: Icons.photo_library_outlined,
      controlBelow: true,
      selected: appModel.videoMiningImageMode,
      options: [
        AdaptiveSettingsPickerOption<VideoMiningImageMode>(
          value: VideoMiningImageMode.gif,
          label: t.video_mining_image_mode_gif,
        ),
        AdaptiveSettingsPickerOption<VideoMiningImageMode>(
          value: VideoMiningImageMode.currentFrame,
          label: t.video_mining_image_mode_current_frame,
        ),
        AdaptiveSettingsPickerOption<VideoMiningImageMode>(
          value: VideoMiningImageMode.subtitleStart,
          label: t.video_mining_image_mode_subtitle_start,
        ),
      ],
      onChanged: (VideoMiningImageMode mode) {
        appModel.setVideoMiningImageMode(mode);
        setState(() {});
      },
    );
  }

  /// galgame 场景卡封面模式，与视频那项**分开存**（`gal_mining_image_mode`）：视频
  /// 动图能拍出口型和动作，galgame 一句台词内画面基本静止，动图多半只是把同一帧存
  /// 二十遍。共用一个开关会逼用户为一边将就另一边。
  ///
  /// galgame 没有「字幕区间」，所以只给 gif / 静态截图两档——不渲染 subtitleStart，
  /// 免得暗示能选一个对这个场景无意义的模式。
  Widget _buildGalMiningImageModePicker() {
    return AdaptiveSettingsPickerRow<VideoMiningImageMode>(
      title: t.gal_mining_image_mode,
      subtitle: t.gal_mining_image_mode_hint,
      icon: Icons.photo_camera_back_outlined,
      controlBelow: true,
      // 历史值可能是 subtitleStart（与视频项共用枚举）：按 isStill 归到静态截图，
      // 不让 picker 落在一个没渲染的选项上。
      selected: appModel.galMiningImageMode.isStill
          ? VideoMiningImageMode.currentFrame
          : VideoMiningImageMode.gif,
      options: [
        AdaptiveSettingsPickerOption<VideoMiningImageMode>(
          value: VideoMiningImageMode.gif,
          label: t.video_mining_image_mode_gif,
        ),
        AdaptiveSettingsPickerOption<VideoMiningImageMode>(
          value: VideoMiningImageMode.currentFrame,
          label: t.gal_mining_image_mode_screenshot,
        ),
      ],
      onChanged: (VideoMiningImageMode mode) {
        appModel.setGalMiningImageMode(mode);
        setState(() {});
      },
    );
  }

  Widget _buildFetchTile(AnkiUiState uiState, AnkiViewModel vm) {
    // Lapis 创建在途时 vm 的 isFetching 也为 true（vm 内部复用同一 flag）；
    // 本行的「正在刷新」文案与 spinner 只对真正的刷新动作显示。
    final bool fetching = uiState.isFetching && !_creatingLapis;
    return AdaptiveSettingsRow(
      icon: Icons.sync_outlined,
      showIcon: true,
      title: fetching ? t.anki_fetching : t.anki_fetch,
      // Platform-neutral refresh hint (TODO-400): this row pulls the *current*
      // deck + note-type snapshot from Anki (AnkiConnect on desktop / iOS,
      // AnkiDroid on Android). The dropdowns only ever render what the last
      // fetch returned, so a deck created/renamed in Anki afterwards stays
      // invisible until the user taps here. The subtitle says exactly that,
      // replacing the old AnkiDroid-only "Fetch from AnkiDroid" label that made
      // desktop AnkiConnect users miss this as the refresh entry point.
      subtitle: fetching ? null : t.anki_refresh_hint,
      // Action row, not navigation: a leading icon + state-layer ripple signals
      // tappability (MD3 list-item convention, same as SettingsActionItem); the
      // tap triggers a fetch (spinner while running) rather than opening a
      // subpage, so there is no trailing chevron.
      trailing: fetching
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      // 任一在途动作（刷新或 Lapis 创建）期间都不可重入。
      onTap: uiState.isFetching || _creatingLapis
          ? null
          : () => vm.fetchConfiguration(),
    );
  }

  Widget _buildCreateLapisTile(AnkiUiState uiState, AnkiViewModel vm) {
    return AdaptiveSettingsRow(
      icon: Icons.note_add_outlined,
      showIcon: true,
      title: t.anki_create_lapis,
      subtitle: t.anki_create_lapis_hint,
      // spinner 只跟本行自己的在途动作（_creatingLapis），不再借 vm 的
      // isFetching——否则点「刷新」时本行也凭空转圈。
      trailing: _creatingLapis
          ? SizedBox(
              width: 20,
              height: 20,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : null,
      onTap: uiState.isFetching || _creatingLapis
          ? null
          : () => _runCreateLapis(vm),
    );
  }

  Future<void> _runCreateLapis(AnkiViewModel vm) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _creatingLapis = true);
    final LapisSetupResult result;
    try {
      result = await vm.createLapisSetup();
    } finally {
      if (mounted) setState(() => _creatingLapis = false);
    }
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

  // ── Lapis 样式客制化 ─────────────────────────────────────────────────

  Future<void> _editLapisCustomCss(
      AnkiSettings settings, AnkiViewModel vm) async {
    final TextEditingController controller =
        TextEditingController(text: settings.lapisCustomCss);
    try {
      await _showLapisCustomCssDialog(controller, vm);
    } finally {
      // 保存路径抛错（写偏好失败）时也必须释放 controller，否则 Flutter 的
      // leak tracking 会把它记成泄漏，且每次打开都多留一个 listener。
      controller.dispose();
    }
  }

  Future<void> _showLapisCustomCssDialog(
      TextEditingController controller, AnkiViewModel vm) async {
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.anki_lapis_custom_css),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 16,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: '.front-vocab { color: #8ab4f8; }',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(t.dialog_save),
          ),
        ],
      ),
    );
    if (result != null) await vm.setLapisCustomCss(result);
  }

  Future<void> _applyLapisStyling(AnkiViewModel vm,
      {bool force = false}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _lapisBusy = true);
    final LapisApplyResult result;
    try {
      result = await vm.lapisTemplateService.applyCustomization(force: force);
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(t.anki_lapis_apply_failed(error: '$e'))));
      return;
    } finally {
      if (mounted) setState(() => _lapisBusy = false);
    }
    if (!mounted) return;
    switch (result) {
      case LapisApplyResult.applied:
        await vm.refreshSettingsFromStore();
        messenger
            .showSnackBar(SnackBar(content: Text(t.anki_lapis_apply_done)));
      case LapisApplyResult.upToDate:
        await vm.refreshSettingsFromStore();
        messenger
            .showSnackBar(SnackBar(content: Text(t.anki_lapis_up_to_date)));
      case LapisApplyResult.needsConfirm:
        final bool? ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: Text(t.anki_lapis_foreign_edit_title),
            content: Text(t.anki_lapis_foreign_edit_body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t.dialog_cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t.dialog_ok),
              ),
            ],
          ),
        );
        if (ok == true && mounted) await _applyLapisStyling(vm, force: true);
      case LapisApplyResult.notFound:
        messenger.showSnackBar(SnackBar(content: Text(t.anki_lapis_not_found)));
      case LapisApplyResult.unsupported:
        // 整区已按 supportsNoteTypeEditing 隐藏，此分支只是防御。
        break;
    }
  }

  Future<void> _backupLapisTemplate(AnkiViewModel vm) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _lapisBusy = true);
    try {
      final LapisBackupOutcome? outcome =
          await vm.lapisTemplateService.backupNow();
      messenger.showSnackBar(SnackBar(
        content: Text(_lapisBackupMessage(outcome)),
      ));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(t.anki_lapis_backup_failed(error: '$e'))));
    } finally {
      if (mounted) setState(() => _lapisBusy = false);
    }
  }

  Future<void> _restoreLapisBackup(AnkiViewModel vm) async {
    // 在第一个 await 之前就占住 _lapisBusy：列备份是异步的，这段窗口里
    // `_lapisBusy ? null : ...` 的门还是开的，第二次点击能进来并开出第二条
    // 恢复流程，两条流程写同一个 note type。占位必须先于任何 await。
    setState(() => _lapisBusy = true);
    try {
      await _runRestoreLapisBackup(vm);
    } finally {
      if (mounted) setState(() => _lapisBusy = false);
    }
  }

  Future<void> _runRestoreLapisBackup(AnkiViewModel vm) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<File> backups = await vm.lapisTemplateService.listBackups();
    if (!mounted) return;
    if (backups.isEmpty) {
      messenger
          .showSnackBar(SnackBar(content: Text(t.anki_lapis_restore_empty)));
      return;
    }
    final File? chosen = await showDialog<File>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(t.anki_lapis_restore),
        children: [
          for (final File f in backups.take(30))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, f),
              child: Text(_lapisBackupLabel(f)),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.anki_lapis_restore),
        content: Text(t.anki_lapis_restore_confirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.dialog_ok),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 两步都可能失败，两步的失败都必须让用户看见：把「第一个失败」收进
    // failure，最后统一出一条 snackbar。刷新**不能**放 finally——finally 里的
    // await 抛出就成了没人接的异步异常（页面继续显示恢复前的值，用户只看到
    // 什么都没发生），正是本 PR 要修的「谎报」同一类问题。
    Object? failure;
    try {
      await vm.lapisTemplateService.restoreBackup(chosen);
    } catch (e) {
      failure = e;
    }
    // 成功失败都要刷：restoreBackup 在卡模板失败前已经把 styling 与 settings
    // 写穿了，只刷成功路径会让页面继续显示恢复前的字号/自定义 CSS。
    try {
      await vm.refreshSettingsFromStore();
    } catch (e) {
      failure ??= e; // 恢复本身的错更接近根因，优先呈现它。
    }
    messenger.showSnackBar(SnackBar(
      content: Text(failure == null
          ? t.anki_lapis_restore_done
          : t.anki_lapis_restore_failed(error: '$failure')),
    ));
  }

  /// 「扫描重复（不改动）」：只跑干跑并把清单摊给用户看，不提供删除按钮。
  Future<void> _scanMediaDedup(AnkiViewModel vm) async {
    final AnkiMediaDedupReport? plan = await _runDedupPass(vm, dryRun: true);
    if (plan == null || !mounted) return;
    await showAnkiMediaDedupPlanDialog(context, plan, offerDelete: false);
  }

  /// 「立即去重」：**永远先干跑**，把「删哪些文件、各占多少空间、保留的是哪
  /// 一份」逐条列给用户；用户在弹窗里点确认之后才跑真删。用户没确认之前一个
  /// 文件都不会动。
  Future<void> _runMediaDedup(AnkiViewModel vm) async {
    final AnkiMediaDedupReport? plan = await _runDedupPass(vm, dryRun: true);
    if (plan == null || !mounted) return;
    final bool confirmed =
        await showAnkiMediaDedupPlanDialog(context, plan, offerDelete: true);
    if (!confirmed || !mounted) return;
    final AnkiMediaDedupReport? result = await _runDedupPass(vm, dryRun: false);
    if (result == null || !mounted) return;
    await showAnkiMediaDedupReportDialog(context, result);
  }

  /// 跑一遍去重（干跑或真跑）。后端不支持 / 出错时给出提示并返回 null。
  Future<AnkiMediaDedupReport?> _runDedupPass(
    AnkiViewModel vm, {
    required bool dryRun,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _dedupBusy = true);
    AnkiMediaDedupReport? report;
    try {
      report = await vm.mediaDedupRunner.runNow(dryRun: dryRun);
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text(t.anki_dedup_failed(error: '$e'))));
      return null;
    } finally {
      if (mounted) setState(() => _dedupBusy = false);
    }
    if (report == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.anki_dedup_unavailable)));
      return null;
    }
    return report;
  }

  /// 手动备份的提示文案：顺带告诉用户按保留策略清理了几份旧备份（删除不可
  /// 逆，必须让用户看得见结果）。
  String _lapisBackupMessage(LapisBackupOutcome? outcome) {
    if (outcome == null) return t.anki_lapis_not_found;
    if (outcome.prunedCount == 0) {
      return t.anki_lapis_backup_done(path: outcome.file.path);
    }
    return t.anki_lapis_backup_done_pruned(
      path: outcome.file.path,
      count: '${outcome.prunedCount}',
    );
  }

  /// 备份文件名 `lapis-<ISO时间戳(冒号→'-')>.json` → 本地可读时间标签；
  /// 解析失败原样显示文件名主体（仍可区分）。时刻解析走
  /// [parseLapisBackupTimestamp]——保留策略用的是同一份判据，两处各写一个
  /// 正则就会出现「界面认得出、清理认不出（于是永不删）」这种静默错位。
  String _lapisBackupLabel(File f) {
    final String name = f.uri.pathSegments.last;
    final DateTime? dt = parseLapisBackupTimestamp(name)?.toLocal();
    if (dt != null) return dt.toString().split('.').first;
    return name.replaceFirst('lapis-', '').replaceFirst('.json', '');
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
    // 隐藏没被用到的旧别名；当前字段正用着的旧别名仍会出现（并标「已弃用」）。
    final options = AnkiHandlebarOptions.optionsForField(
      dictionaryNames: dictionaryNames,
      currentValue: currentValue,
    );

    final result = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AnkiHandlebarPickerDialog(
        title: t.anki_select_handlebar(field: field),
        initialValue: currentValue,
        options: options,
        labelFor: ankiHandlebarLabel,
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

  /// 查重范围单选。Anki 的 `deck:X` 包含 X 的子卡组，但**不包含**父卡组与
  /// 兄弟子卡组，所以把制卡目标选成 `Lapis::Vocab` 时，同一个词早先制在
  /// `Lapis::Sentences` 里就查不到、被当成新词（Yomitan 对应 duplicate scope）。
  /// deckRoot = 根卡组及其全部子卡组；collection = 不限卡组。仅 AnkiConnect
  /// 生效（AnkiDroid 经 ContentProvider 按笔记类型全库查，本就等价 collection）。
  Widget _buildDuplicateScopePicker(AnkiSettings settings, AnkiViewModel vm) {
    return AdaptiveSettingsPickerRow<AnkiDuplicateScope>(
      title: t.anki_duplicate_scope,
      subtitle: t.anki_duplicate_scope_hint,
      controlBelow: true,
      selected: settings.duplicateScope,
      options: [
        AdaptiveSettingsPickerOption<AnkiDuplicateScope>(
          value: AnkiDuplicateScope.deck,
          label: t.anki_duplicate_scope_deck,
        ),
        AdaptiveSettingsPickerOption<AnkiDuplicateScope>(
          value: AnkiDuplicateScope.deckRoot,
          label: t.anki_duplicate_scope_deck_root,
        ),
        AdaptiveSettingsPickerOption<AnkiDuplicateScope>(
          value: AnkiDuplicateScope.collection,
          label: t.anki_duplicate_scope_collection,
        ),
      ],
      onChanged: (scope) => vm.updateDuplicateScope(scope),
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

/// 把 Anki 占位符字面量（如 `{book-cover}`）映射成本地化友好标签（如「Book Cover」）。
///
/// **纯展示**：只用于 picker 列表显示，绝不改变写进 `fieldMappings` 的字面量真值
/// （渲染器认的是字面量）。未识别 / 动态占位符回退原字面量，绝不返回空白：
/// - `{single-glossary-<dict>}` → 直接显示词典名 `<dict>`（零新 i18n key）。
/// - 其它未知占位符 → 原样返回 `option`（向后兼容）。
/// - [AnkiHandlebarOptions.deprecatedAliases] 里的旧别名额外套一层「已弃用」标注，
///   提示改用等价新键；标注只是展示，渲染器照旧认这些别名，行为完全不变。
String ankiHandlebarLabel(String option) {
  const String singleGlossaryPrefix = '{single-glossary-';
  if (option.startsWith(singleGlossaryPrefix) && option.endsWith('}')) {
    return option.substring(singleGlossaryPrefix.length, option.length - 1);
  }
  final String base = _ankiHandlebarBaseLabel(option);
  return AnkiHandlebarOptions.deprecatedAliases.contains(option)
      ? t.handlebar_deprecated_label(label: base)
      : base;
}

/// [ankiHandlebarLabel] 的裸标签部分（不含「已弃用」标注）。
String _ankiHandlebarBaseLabel(String option) {
  switch (option) {
    case '{expression}':
      return t.handlebar_expression;
    case '{reading}':
      return t.handlebar_reading;
    case '{furigana-plain}':
      return t.handlebar_furigana_plain;
    case '{audio}':
      return t.handlebar_audio;
    case '{glossary}':
      return t.handlebar_glossary;
    case '{glossary-first}':
      return t.handlebar_glossary_first;
    case '{selected-glossary}':
      return t.handlebar_selected_glossary;
    case '{popup-selection-text}':
      return t.handlebar_popup_selection_text;
    case '{sentence}':
      return t.handlebar_sentence;
    case '{cue-sentence}':
      return t.handlebar_cue_sentence;
    case '{frequencies}':
      return t.handlebar_frequencies;
    case '{frequency-harmonic-rank}':
      return t.handlebar_frequency_harmonic_rank;
    case '{pitch-accent-positions}':
      return t.handlebar_pitch_accent_positions;
    case '{pitch-accent-categories}':
      return t.handlebar_pitch_accent_categories;
    case '{phonetic-transcriptions}':
      return t.handlebar_phonetic_transcriptions;
    case '{document-title}':
      return t.handlebar_document_title;
    case '{card-image}':
      return t.handlebar_card_image;
    case '{book-cover}':
      return t.handlebar_book_cover;
    case '{video-clip}':
      return t.handlebar_video_clip;
    case '{sentence-audio}':
      return t.handlebar_sentence_audio;
    case '{sasayaki-audio}':
      return t.handlebar_sasayaki_audio;
    default:
      return option;
  }
}

/// 默认标签回调：恒等返回原字面量（const 构造器默认值需顶层函数）。
String _identityLabel(String option) => option;

@visibleForTesting
class AnkiHandlebarPickerDialog extends StatefulWidget {
  const AnkiHandlebarPickerDialog({
    required this.title,
    required this.initialValue,
    required this.options,
    this.labelFor = _identityLabel,
    super.key,
  });

  final String title;
  final String initialValue;
  final List<String> options;

  /// 占位符字面量 → 显示标签的纯展示映射（默认恒等：显示原字面量，向后兼容）。
  /// 选中 / 比较 / 写入仍全程用字面量，只有列表显示走此回调。
  final String Function(String option) labelFor;

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
              // 选中勾对照**当前输入框值**而非打开时的旧快照（initialValue）：
              // 用户在输入框里改过映射后，勾要实时跟着走，不再指向已过时的旧值。
              // ValueListenableBuilder 只重建选项列表，键入不重建整个弹窗。
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (BuildContext context, TextEditingValue value, _) {
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: widget.options.length,
                    itemBuilder: (_, i) {
                      final opt = widget.options[i];
                      if (opt == '-') return const Divider(height: 1);
                      final bool isSelected = value.text == opt;
                      return AdaptiveSettingsRow(
                        title: widget.labelFor(opt),
                        trailing: isSelected
                            ? Icon(
                                Icons.check,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        onTap: () => Navigator.pop(context, opt),
                      );
                    },
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
            // 统一走 slang t.*（MaterialLocalizations 跟系统 locale，与应用内
            // 语言切换脱节）。首按钮语义是「清空该字段映射」而非删除实体，
            // 用 dialog_clear。
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, ''),
              child: Text(t.dialog_clear),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, _controller.text),
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}
