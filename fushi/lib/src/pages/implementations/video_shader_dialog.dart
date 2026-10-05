import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';

/// mpv 着色器内嵌管理视图：导入 `.glsl`/`.hook`、从本机 mpv 发现导入、一键下载
/// Anime4K 推荐预设、勾选启用、即时应用。直接嵌进视频设置面板的「着色器」详情 pane
/// （不再弹独立设置对话框，与书籍设置同款内嵌范式）。
///
/// 自身只管文件列表与勾选状态；启用集（按文件名）经 [onApply] 上报给视频页，由其
/// 持久化 + 解析成绝对路径 + 调 `VideoPlayerController.applyShaders` 实时生效（五平台
/// libmpv 后端均生效——移动端走 vo=gpu 渲染路径，非 no-op；效果因机型 GPU 而异、高档可能
/// 掉帧，UI 用 [t.video_shader_mobile_perf_hint] 提示，见 video_shader_manager.dart doc
/// 的 media_kit 源码出处）。勾选顺序按目录列表顺序，保证着色器叠加顺序稳定。
///
/// 「下载 Anime4K」「从本机 mpv 导入」「导入文件」是**瞬时动作**（弹临时选择/进度对话框
/// 或系统文件选择器），不是设置子页面——它们完成后回到本内嵌视图。
class VideoShaderManagerView extends StatefulWidget {
  const VideoShaderManagerView({
    required this.initialEnabled,
    required this.qualityEnhancementEnabled,
    required this.onQualityEnhancementChanged,
    required this.onApply,
    required this.onSelectTier,
    this.initialMpvDir = '',
    this.onMpvDirChanged,
    this.embedded = false,
    this.titlePlacement = SettingsSectionTitlePlacement.outside,
    super.key,
  });

  /// 初始启用的着色器文件名集合。
  final List<String> initialEnabled;

  /// 整个画质增强组是否启用。关闭时保留勾选集，但运行时由调用方旁路 shader。
  final bool qualityEnhancementEnabled;

  /// 切换画质增强组：调用方负责持久化 mpv 基础增强并即时应用/旁路 shader。
  final void Function(bool enabled) onQualityEnhancementChanged;

  /// 勾选变化时回调，参数为按目录顺序排列的启用文件名列表。
  final Future<void> Function(List<String> enabledNames) onApply;

  /// 选某画质档位后回调：本视图已把目标状态算好——[highQuality]（mpv 内置缩放开关）
  /// 与 [enabledNames]（按叠加顺序、已落盘存在的该档着色器集）。调用方一次性持久化这
  /// 两套状态 + 实时应用（着色器文件已由本视图在回调前下载到目录）。[tier] 仅供日志/统计。
  final Future<void> Function(
    VideoShaderTier tier,
    bool highQuality,
    List<String> enabledNames,
  ) onSelectTier;

  /// 用户上次手动指定的本机 mpv 配置/着色器目录（空=未指定，走自动候选）。
  final String initialMpvDir;

  /// 用户手动指定 mpv 目录后回调（持久化，下次优先扫它）。
  final Future<void> Function(String dir)? onMpvDirChanged;

  /// 嵌入已有设置 surface 时只渲染分组标题、行与分隔线，避免在外层卡片里再次
  /// 套三张 [AdaptiveSettingsSection] 卡片。独立页面保持原来的分组卡片布局。
  final bool embedded;

  final SettingsSectionTitlePlacement titlePlacement;

  @override
  State<VideoShaderManagerView> createState() => _VideoShaderManagerViewState();
}

class _VideoShaderManagerViewState extends State<VideoShaderManagerView>
    with FushiPagePlaceholders<VideoShaderManagerView> {
  late final Set<String> _enabled = widget.initialEnabled.toSet();
  late String _mpvDir = widget.initialMpvDir;
  List<String> _files = const <String>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final List<String> files = await listShaderFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _import() async {
    final FilePickerResult? result = await pickFilesByExtensions(
      context: context,
      allowedExtensions: const <String>['glsl', 'hook'],
      allowMultiple: true,
    );
    if (result == null) return;
    for (final PlatformFile f in result.files) {
      final String? path = f.path;
      if (path != null) await importShaderFile(path);
    }
    await _refresh();
  }

  /// 从本机 mpv 安装发现着色器（手动指定目录优先，再叠加自动候选目录的 `shaders/`）
  /// → 多选导入到 mpv_shaders。自动扫不到时**引导手动指定 mpv 目录**（见
  /// [_pickMpvDirAndSearch]）。
  Future<void> _importFromMpv() async {
    final List<String> found =
        await discoverLocalMpvShaders(overrideDir: _mpvDir);
    if (!mounted) return;
    if (found.isEmpty) {
      // 自动找不到：直接转入「手动指定目录并搜索」，而不是只弹个失败提示（用户诉求）。
      await _pickMpvDirAndSearch(autoFallback: true);
      return;
    }
    await _pickAndImportFrom(found);
  }

  /// 手动指定本机 mpv 配置/着色器目录 → 扫描 → 多选导入；记住该目录下次优先。
  /// [autoFallback]=true 表示这是「自动找不到」转过来的（首句提示语略不同）。
  Future<void> _pickMpvDirAndSearch({bool autoFallback = false}) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // 选中的目录随后要被 `dart:io` 遍历（扫 .glsl/.hook），必须是真实路径。
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel:
          ProviderScope.containerOf(context, listen: false).read(appProvider),
      dialogTitle: t.video_shader_pick_mpv_dir,
      initialDirectory: _mpvDir.isNotEmpty ? _mpvDir : null,
    );
    if (dir == null || !mounted) {
      if (autoFallback) {
        messenger.showSnackBar(
            FushiSnackBar(content: Text(t.video_shader_mpv_not_found)));
      }
      return;
    }
    setState(() => _mpvDir = dir);
    await widget.onMpvDirChanged?.call(dir);
    final List<String> found = await discoverLocalMpvShaders(overrideDir: dir);
    if (!mounted) return;
    if (found.isEmpty) {
      messenger
          .showSnackBar(FushiSnackBar(content: Text(t.video_shader_mpv_dir_empty)));
      return;
    }
    await _pickAndImportFrom(found);
  }

  /// 把发现到的着色器列出多选 → 导入选中的到 mpv_shaders → 刷新 + 提示。
  Future<void> _pickAndImportFrom(List<String> found) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<String>? picked = await showAppDialog<List<String>>(
      context: context,
      builder: (_) => _MpvShaderPickerDialog(
        discovered: found,
        alreadyImported: _files.toSet(),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    for (final String path in picked) {
      await importShaderFile(path);
    }
    await _refresh();
    if (!mounted) return;
    messenger.showSnackBar(
      FushiSnackBar(content: Text(t.video_shader_import_done(count: picked.length))),
    );
  }

  Future<void> _toggle(String name, bool on) async {
    setState(() {
      if (on) {
        _enabled.add(name);
      } else {
        _enabled.remove(name);
      }
    });
    // 按目录列表顺序排出启用集，保证着色器叠加顺序稳定可复现。
    final List<String> ordered =
        _files.where(_enabled.contains).toList(growable: false);
    await widget.onApply(ordered);
  }

  /// 粘贴任意着色器链接（GitHub/直链）下载到 mpv_shaders——不必本机装 mpv（用户诉求）。
  /// **直链优先**：先试用户粘的链接本身，跑不通才回退 jsDelivr/ghfast 镜像（中国可达），
  /// 内容校验防 404/HTML 占位。
  Future<void> _downloadFromUrl() async {
    final TextEditingController urlController = TextEditingController();
    final String? url = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) => FushiAlertDialog(
        title: Text(t.video_shader_download_url),
        content: FushiTextFieldControl(
          controller: urlController,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: t.video_shader_url_hint),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_cancel),
          ),
          FushiTextButton(
            onPressed: () => Navigator.pop(ctx, urlController.text),
            child: Text(t.dialog_save),
          ),
        ],
      ),
    );
    urlController.dispose();
    final String? trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      FushiSnackBar(content: Text(t.video_shader_downloading)),
    );
    String? name;
    try {
      name = await downloadShaderFromUrl(trimmed);
    } catch (_) {
      name = null;
    }
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    messenger.showSnackBar(FushiSnackBar(
      content: Text(name != null
          ? t.video_shader_download_done(count: 1)
          : t.video_shader_download_failed),
    ));
  }

  /// 下载某预设的全部着色器到 mpv_shaders（进度对话框 + 取消），完成刷新列表 + 提示。
  /// 返回 true 表示该预设的全部文件现已就绪（全部下载成功或已存在），可据此启用该档。
  Future<bool> _downloadPreset(Anime4kPreset preset) async {
    final ValueNotifier<({int index, int total, double? progress})>
        progressNotifier =
        ValueNotifier<({int index, int total, double? progress})>(
            (index: 0, total: preset.shaders.length, progress: null));
    final CancelToken cancelToken = CancelToken();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // 在弹框之前拿住 navigator：收尾时的那次 pop 不能依赖本 State 还 mounted
    // （见下方注释）。
    final NavigatorState navigator = Navigator.of(context);

    // 进度对话框：取消只置 cancelToken（不自己 pop），关闭统一由本方法在下载收尾时
    // 做一次 pop——保证「关进度框」只有一条路径，不会与取消路径重复 pop 误伤视频页路由。
    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        // 返回等价于「取消下载」，而不是被静默吞掉：pop 仍只由收尾那一处执行，
        // 这里只置 cancelToken，下载随即以 cancel 结束并走到那次 pop。
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (didPop) return;
          cancelToken.cancel();
        },
        child: _Anime4kProgressDialog(
          presetName: preset.name,
          progressNotifier: progressNotifier,
          onCancel: cancelToken.cancel,
        ),
      ),
    );

    Anime4kDownloadResult? result;
    Object? error;
    bool cancelled = false;
    try {
      result = await downloadAnime4kFiles(
        preset,
        cancelToken: cancelToken,
        onFileProgress: (int i, int total, double? p) {
          progressNotifier.value = (index: i, total: total, progress: p);
        },
      );
    } on DioError catch (e) {
      if (e.type == DioErrorType.cancel) {
        cancelled = true;
      } else {
        error = e;
      }
    } catch (e) {
      error = e;
    } finally {
      progressNotifier.dispose();
    }

    // 关闭进度对话框（唯一一次 pop）。**不能挂在 `mounted` 后面**：这个框是
    // `barrierDismissible: false` + `canPop: false`，视频页在下载期间被换掉
    // （pushReplacement 到网页播放器、自动换集、页面销毁）本 State 就 unmounted，
    // 旧写法那句 pop 于是永远不执行，一个 barrier 点不掉、返回被吞、按钮又只置
    // cancelToken 不自闭的全屏模态就永久留在屏幕上——iOS 既没有系统返回键、
    // 对话框路由也没有侧滑返回，用户只能杀进程。
    if (navigator.canPop()) {
      navigator.pop();
    }
    if (!mounted) return false;
    await _refresh();
    if (!mounted || cancelled) return false;

    if (error != null) {
      messenger.showSnackBar(
        FushiSnackBar(content: Text(t.video_shader_download_failed)),
      );
      return false;
    }
    if (result == null) return false; // 被取消。
    final String message;
    if (result.allOk) {
      message = t.video_shader_download_done(count: result.downloaded.length);
    } else if (result.downloaded.isNotEmpty) {
      message = t.video_shader_download_partial(
        ok: result.downloaded.length,
        failed: result.failed.length,
      );
    } else {
      message = t.video_shader_download_failed;
    }
    messenger.showSnackBar(FushiSnackBar(content: Text(message)));
    return result.allOk;
  }

  /// **一键画质档位切换**（用户诉求 1/3/4 的统一入口）：选 [tier] 后——
  /// 1) 若该档需要 GLSL 且文件未全就绪 → 走 [_downloadPreset] 下载（带进度，可取消）；
  /// 2) 下载成功 / 无需下载 → 刷新目录，调 [VideoShaderManagerView.onSelectTier]
  ///    让视频页一次性写「内置缩放开关 + 启用集」并实时应用。
  /// 下载失败（用户取消 / 网络全挂）则不改档，停在原状态（不留半启用）。
  Future<void> _selectTier(VideoShaderTier tier) async {
    final VideoShaderTierSpec spec = shaderTierSpec(tier);
    final Anime4kPreset? preset = spec.preset;
    if (preset != null) {
      final bool alreadyHave = preset.fileNames.every(_files.toSet().contains);
      if (!alreadyHave) {
        final bool ok =
            await _downloadPreset(preset); // 内部已 _refresh 刷新 _files。
        if (!mounted || !ok) return; // 取消/失败：不切档（不留半启用）。
      }
    }
    // 从目录现有文件按该档叠加顺序过滤出有序启用集（个别下载失败也只启用存在的）。
    final List<String> enabled = orderedEnabledForTier(tier, _files.toSet());
    setState(() {
      _enabled
        ..clear()
        ..addAll(enabled);
    });
    await widget.onSelectTier(tier, spec.highQuality, enabled);
    if (mounted) setState(() {}); // 重算当前选中档高亮。
  }

  /// 当前命中的画质档（据内置缩放开关 + 已启用集反查）；都不命中=用户自定义勾选→null。
  VideoShaderTier? get _currentTier => tierFromState(
        highQuality: widget.qualityEnhancementEnabled,
        enabledShaders: _files.where(_enabled.contains).toList(),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(height: 80, child: buildLoading());
    }
    final List<Widget> installedRows = _files.isEmpty
        ? <Widget>[
            AdaptiveSettingsRow(
              title: t.video_shaders_empty,
              icon: Icons.hourglass_empty_outlined,
              showIcon: true,
            ),
          ]
        : _installedShaderRows();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ── 画质档位（无/低/中/高/极高）：一键选档即下载+启用，普通用户唯一需要的入口 ──
        _shaderSection(
          title: t.video_shader_quality_tier,
          first: true,
          children: <Widget>[
            VideoShaderTierSelector(
              current: _currentTier,
              onSelect: _selectTier,
            ),
            // 选档前就把五档「档名 — 一句话 + 显卡要求」常驻列出，便于横向比较，
            // 不用点开某档才看到要求（用户诉求 2）。当前命中档加粗高亮。
            VideoShaderTierComparison(
              current: _currentTier,
              onSelect: _selectTier,
            ),
            if (_currentTier == null)
              _ShaderFootnote(text: t.video_shader_tier_custom_hint),
            if (isMobilePlatform)
              _ShaderFootnote(
                text: t.video_shader_mobile_perf_hint,
                warning: true,
              ),
          ],
        ),
        // ── 进阶：手动导入文件 / 粘贴链接下载 / 从本机 mpv 导入（给懂的人用的逃生口）──
        _shaderSection(
          title: t.video_shader_section_advanced,
          children: <Widget>[
            _actionRow(
              title: t.video_shader_import,
              icon: Icons.add_outlined,
              onTap: _import,
            ),
            _actionRow(
              title: t.video_shader_download_url,
              subtitle: t.video_shader_url_hint,
              icon: Icons.link_outlined,
              onTap: _downloadFromUrl,
            ),
            _actionRow(
              title: t.video_shader_import_from_mpv,
              subtitle: _mpvDir.isEmpty
                  ? t.video_shader_import_from_mpv_hint
                  : t.video_shader_mpv_dir_current(path: _mpvDir),
              icon: Icons.travel_explore_outlined,
              onTap: _importFromMpv,
            ),
          ],
        ),
        _shaderSection(
          title: t.video_shader_section_installed,
          children: installedRows,
        ),
      ],
    );
  }

  /// 已安装着色器 → 设置开关行（与上方导入行同一行组件、同一文字起点）。
  ///
  /// 文件名按前缀分组（`Anime4K_…` / `ArtCNN_…`）：同前缀至少两个文件时在组前
  /// 挂一个小组名，组内行标题去掉前缀与扩展名、下划线换空格（「Restore CNN M」），
  /// 副标题保留完整文件名——人读标题、文件身份照样一眼可查。显示顺序按组首次出现
  /// 的位置聚拢，**启用集顺序仍按 [_files] 目录顺序**（见 [_toggle]），不受影响。
  List<Widget> _installedShaderRows() {
    final Map<String, List<String>> groups = <String, List<String>>{};
    for (final String name in _files) {
      groups.putIfAbsent(_shaderFamily(name), () => <String>[]).add(name);
    }
    final List<String> loose = <String>[
      for (final MapEntry<String, List<String>> entry in groups.entries)
        if (entry.key.isEmpty || entry.value.length < 2) ...entry.value,
    ];
    final List<Widget> rows = <Widget>[
      for (final String name in loose) _shaderRow(name, family: ''),
    ];
    for (final MapEntry<String, List<String>> entry in groups.entries) {
      if (entry.key.isEmpty || entry.value.length < 2) continue;
      rows.add(_ShaderGroupLabel(text: entry.key));
      for (final String name in entry.value) {
        rows.add(_shaderRow(name, family: entry.key));
      }
    }
    return rows;
  }

  /// 文件名的系列前缀（第一个 `_` 之前）；没有下划线 = 无系列。
  static String _shaderFamily(String name) {
    final String stem = p.basenameWithoutExtension(name);
    final int cut = stem.indexOf('_');
    return cut <= 0 ? '' : stem.substring(0, cut);
  }

  Widget _shaderRow(String name, {required String family}) {
    String title = p.basenameWithoutExtension(name);
    if (family.isNotEmpty && title.length > family.length + 1) {
      title = title.substring(family.length + 1);
    }
    title = title.replaceAll('_', ' ');
    return AdaptiveSettingsSwitchRow(
      key: ValueKey<String>('video-shader-file-$name'),
      title: title,
      subtitle: name,
      icon: Icons.auto_awesome_outlined,
      showIcon: true,
      value: _enabled.contains(name),
      onChanged: (bool v) => _toggle(name, v),
    );
  }

  Widget _shaderSection({
    required String title,
    required List<Widget> children,
    bool first = false,
  }) {
    if (!widget.embedded) {
      return AdaptiveSettingsSection(
        title: title,
        titlePlacement: widget.titlePlacement,
        children: children,
      );
    }
    return _EmbeddedShaderSection(
      title: title,
      showTopDivider: !first,
      children: children,
    );
  }

  AdaptiveSettingsRow _actionRow({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: true,
      trailing: const FushiIcon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 已有 settings surface 内的扁平分组：只渲染分组标题与行，不再创建卡片（外层
/// 设置卡就是这一页的唯一底板，守卫见 video_player_settings_master_detail_guard）。
///
/// - MD3（Android 16 设置）：分组标题与其它分类页的分段分组标题同一口径
///   （titleSmall · primary · w600，左缘对齐行内边距）；行与行之间不画分隔线——
///   卡片里的设置行靠 64 行高与留白分节，分隔线只会让它变回一张表格。
/// - Apple（iOS 26 inset grouped）：分组标题走 [SettingsSectionHeader] 的 Apple
///   分支（13 号 semibold secondaryLabel）；行间 1 物理像素 separator，从文字
///   起点（有行首图标时从图标之后）开始，与 schema 分组同一条缩进规则；分组之间
///   一条通栏 separator。
class _EmbeddedShaderSection extends StatelessWidget {
  const _EmbeddedShaderSection({
    required this.title,
    required this.children,
    required this.showTopDivider,
  });

  final String title;
  final List<Widget> children;
  final bool showTopDivider;

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final double inset = tokens.spacing.rowHorizontal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showTopDivider && glass) const _AppleSeparator(flush: true),
        if (glass)
          SettingsSectionHeader(
            title,
            padding: EdgeInsets.fromLTRB(inset, 14, inset, 4),
          )
        else
          Padding(
            padding: EdgeInsets.fromLTRB(
              inset,
              showTopDivider ? tokens.spacing.card : tokens.spacing.gap * 2,
              inset,
              tokens.spacing.gap / 2,
            ),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: isEinkTheme(context)
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        for (int index = 0; index < children.length; index++) ...<Widget>[
          if (glass &&
              index > 0 &&
              children[index] is! _ShaderGroupLabel &&
              children[index] is! _ShaderFootnote &&
              children[index - 1] is! _ShaderGroupLabel)
            _AppleSeparator(
              afterIcon: settingsRowHasLeadingIcon(children[index - 1]),
            ),
          children[index],
        ],
      ],
    );
  }
}

/// Apple inset grouped 行分隔线：1 物理像素 separator，右端顶到分组边缘。
/// [flush] = 分组之间的通栏线；否则左端从行文字起点开始（[afterIcon] 时再让过
/// 行首图标位），与 schema 分组的分隔线缩进同一规则。
class _AppleSeparator extends StatelessWidget {
  const _AppleSeparator({this.afterIcon = false, this.flush = false});

  final bool afterIcon;
  final bool flush;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final double start = flush
        ? 0
        : metrics.rowHorizontal +
            (afterIcon
                ? metrics.iconTileSize +
                    FushiDesignTokens.of(context).spacing.gap +
                    4
                : 0);
    return Container(
      height: fushiHairline(context),
      margin: EdgeInsetsDirectional.only(start: start),
      color: appleColorsOf(context).separator,
    );
  }
}

/// 已安装着色器按系列前缀分组时的小组名（`Anime4K` / `ArtCNN`）：比分组标题低
/// 一级，左缘与行文字起点（图标之后）对齐，读起来是「组 → 子组 → 行」。
class _ShaderGroupLabel extends StatelessWidget {
  const _ShaderGroupLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final double iconColumn = glass
        ? FushiAppleMetrics.of(context).iconTileSize
        : 30;
    final TextStyle? style = glass
        ? FushiAppleMetrics.of(context).footnoteStyle(context)
        : Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.rowHorizontal + iconColumn + tokens.spacing.gap + 4,
        tokens.spacing.gap + 2,
        tokens.spacing.rowHorizontal,
        glass ? 2 : 0,
      ),
      child: Text(text, style: style),
    );
  }
}

/// 档位区下方的一行说明（自定义勾选提示 / 移动端性能提示）：与行文字同一左缘，
/// MD3 bodySmall onSurfaceVariant（[warning] 用 tertiary），Apple footnote 灰字
/// （[warning] 用系统橙）。
class _ShaderFootnote extends StatelessWidget {
  const _ShaderFootnote({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = isGlassDesign(context)
        ? FushiAppleMetrics.of(context).footnoteStyle(context).copyWith(
              color: warning ? appleColorsOf(context).warning : null,
            )
        : theme.textTheme.bodySmall?.copyWith(
            color: warning
                ? theme.colorScheme.tertiary
                : theme.colorScheme.onSurfaceVariant,
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.rowHorizontal,
        2,
        tokens.spacing.rowHorizontal,
        tokens.spacing.gap,
      ),
      child: Text(text, style: style),
    );
  }
}

/// 从本机 mpv 发现的着色器多选导入对话框：列出绝对路径的 basename，已在 mpv_shaders
/// 里的标「已导入」并禁选；点「导入」pop 回选中的绝对路径列表，取消 pop null。
class _MpvShaderPickerDialog extends StatefulWidget {
  const _MpvShaderPickerDialog({
    required this.discovered,
    required this.alreadyImported,
  });

  /// 发现到的着色器绝对路径。
  final List<String> discovered;

  /// 已在 mpv_shaders 目录里的文件名（basename），用于标「已导入」并禁选。
  final Set<String> alreadyImported;

  @override
  State<_MpvShaderPickerDialog> createState() => _MpvShaderPickerDialogState();
}

class _MpvShaderPickerDialogState extends State<_MpvShaderPickerDialog> {
  // 默认勾选所有尚未导入的；已导入的不勾（也禁选）。
  late final Set<String> _selected = <String>{
    for (final String path in widget.discovered)
      if (!widget.alreadyImported.contains(p.basename(path))) path,
  };

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Text(t.video_shader_mpv_pick_title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final String path in widget.discovered)
                    () {
                      final String name = p.basename(path);
                      final bool imported =
                          widget.alreadyImported.contains(name);
                      return FushiCheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(name, overflow: TextOverflow.ellipsis),
                        subtitle: imported
                            ? Text(t.video_shader_downloaded_label)
                            : null,
                        value: imported || _selected.contains(path),
                        onChanged: imported
                            ? null
                            : (bool? v) => setState(() {
                                  if (v ?? false) {
                                    _selected.add(path);
                                  } else {
                                    _selected.remove(path);
                                  }
                                }),
                      );
                    }(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: Text(t.video_shader_import),
        ),
      ],
    );
  }
}

/// Anime4K 推荐预设选择对话框：列出 [kAnime4kPresets]，点某项 pop 回该预设；已下载
/// 全部文件的预设标「已下载」。预设标题用技术名（Mode A/B/C），说明走 i18n。
@visibleForTesting
class Anime4kPresetPickerDialog extends StatelessWidget {
  const Anime4kPresetPickerDialog({
    required this.downloadedFiles,
    super.key,
  });

  /// 当前 mpv_shaders 目录已有的文件名集合（判预设是否「已下载」）。
  final Set<String> downloadedFiles;

  /// 预设 id → 本地化说明文案。
  static String presetDescription(String id) {
    switch (id) {
      case 'mode_a_fast':
        return t.video_shader_preset_mode_a_fast;
      case 'mode_b_fast':
        return t.video_shader_preset_mode_b_fast;
      case 'mode_c_fast':
        return t.video_shader_preset_mode_c_fast;
      case 'mode_a_hq':
        return t.video_shader_preset_mode_a_hq;
      case 'mode_b_hq':
        return t.video_shader_preset_mode_b_hq;
      case 'mode_c_hq':
        return t.video_shader_preset_mode_c_hq;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiAlertDialog(
      title: Text(t.video_shader_anime4k_title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.video_shader_anime4k_hint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final Anime4kPreset preset in kAnime4kPresets)
                    () {
                      final bool added =
                          preset.fileNames.every(downloadedFiles.contains);
                      // BUG-1425：预设选择行走共享 MD3 组件，不再裸 ListTile。
                      // 本文件的 reviewed 豁免只写了「导入的 shader 文件以勾选行
                      // 列出」（即那两处 CheckboxListTile），从不覆盖这个预设列表。
                      return FushiListItem(
                        padding: EdgeInsets.symmetric(
                          vertical:
                              FushiDesignTokens.of(context).spacing.rowVertical,
                        ),
                        title: Text(preset.name),
                        // 预设说明是两三句话，裸 ListTile 的 subtitle 不截行；
                        // 收口后显式放宽到 3 行，别让长语言（英/德）被吃掉半句。
                        subtitleMaxLines: 3,
                        subtitle: Text(presetDescription(preset.id)),
                        trailing: added
                            ? FushiIcon(Icons.check, color: cs.primary)
                            : const FushiIcon(Icons.download_outlined),
                        onTap: () => Navigator.pop(context, preset),
                      );
                    }(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiFilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}

/// Anime4K 下载进度对话框：显示「文件 i/N」+ 当前文件百分比 + 取消。
class _Anime4kProgressDialog extends StatelessWidget {
  const _Anime4kProgressDialog({
    required this.presetName,
    required this.progressNotifier,
    required this.onCancel,
  });

  final String presetName;
  final ValueNotifier<({int index, int total, double? progress})>
      progressNotifier;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Text(t.video_shader_downloading),
      content: SizedBox(
        width: 320,
        child:
            ValueListenableBuilder<({int index, int total, double? progress})>(
          valueListenable: progressNotifier,
          builder: (_, ({int index, int total, double? progress}) v, __) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(presetName, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 12),
                FushiLinearProgressIndicator(value: v.progress),
                const SizedBox(height: 8),
                Text(
                  '${v.index + 1} / ${v.total}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: onCancel,
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }
}

/// 画质档位 i18n 标签（无/低/中/高/极高）。纯映射。
String shaderTierLabel(VideoShaderTier tier) {
  switch (tier) {
    case VideoShaderTier.off:
      return t.video_shader_tier_off;
    case VideoShaderTier.low:
      return t.video_shader_tier_low;
    case VideoShaderTier.medium:
      return t.video_shader_tier_medium;
    case VideoShaderTier.high:
      return t.video_shader_tier_high;
    case VideoShaderTier.ultra:
      return t.video_shader_tier_ultra;
  }
}

/// 画质档位一句话说明（选谁用谁，告诉用户该档画质/GPU 取舍）。纯映射。
///
/// **按平台分文案**：中/高/极高 在两端映射到不同的着色器链（见 [shaderTiersFor]），
/// 桌面文案写的是「Anime4K HQ / 需要 RTX 4060」这类**桌面显卡门槛**，照搬到手机上等于
/// 让用户按一个不存在的标准选档——这正是「手机上选了中档就卡」的表层诱因。移动端换成
/// 描述「只修复不放大」的那套文案。
String shaderTierLabelDescription(VideoShaderTier tier, {bool? isMobile}) {
  final bool mobile = isMobile ?? isMobilePlatform;
  if (mobile) {
    switch (tier) {
      case VideoShaderTier.off:
        return t.video_shader_tier_off_hint;
      case VideoShaderTier.low:
        return t.video_shader_tier_low_hint_mobile;
      case VideoShaderTier.medium:
        return t.video_shader_tier_medium_hint_mobile;
      case VideoShaderTier.high:
        return t.video_shader_tier_high_hint_mobile;
      case VideoShaderTier.ultra:
        return t.video_shader_tier_ultra_hint_mobile;
    }
  }
  switch (tier) {
    case VideoShaderTier.off:
      return t.video_shader_tier_off_hint;
    case VideoShaderTier.low:
      return t.video_shader_tier_low_hint;
    case VideoShaderTier.medium:
      return t.video_shader_tier_medium_hint;
    case VideoShaderTier.high:
      return t.video_shader_tier_high_hint;
    case VideoShaderTier.ultra:
      return t.video_shader_tier_ultra_hint;
  }
}

/// 画质档位单选器：横排五个分段按钮（无/低/中/高/极高），选中即回调 [onSelect]。
/// [current]=null（用户手工自定义勾选）时不高亮任何分段，用户仍可点任一档覆盖回标准档。
///
/// 用 [SegmentedButton]（MD3 单选）——五档互斥，选一个即整体切换底层两套状态，
/// 不让用户对着一堆陌生着色器名逐个勾（用户诉求）。窄屏不下时分段按钮自动横向滚动。
class VideoShaderTierSelector extends StatelessWidget {
  const VideoShaderTierSelector({
    required this.current,
    required this.onSelect,
    super.key,
  });

  /// 当前命中的档（null=自定义，不选中任何分段）。
  final VideoShaderTier? current;

  /// 选某档回调。
  final Future<void> Function(VideoShaderTier tier) onSelect;

  @override
  Widget build(BuildContext context) {
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 与设置行同一左缘（rowHorizontal），上下留出与行间距同档的呼吸。
        padding: EdgeInsets.symmetric(
          horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
          vertical: FushiDesignTokens.of(context).spacing.gap,
        ),
        child: FushiSegmentedButton<VideoShaderTier>(
          segments: <ButtonSegment<VideoShaderTier>>[
            for (final VideoShaderTierSpec spec in shaderTiersFor())
              ButtonSegment<VideoShaderTier>(
                value: spec.tier,
                label: Text(shaderTierLabel(spec.tier)),
              ),
          ],
          selected: current == null
              ? <VideoShaderTier>{}
              : <VideoShaderTier>{current!},
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          multiSelectionEnabled: false,
          onSelectionChanged: (Set<VideoShaderTier> selection) {
            if (selection.isEmpty) return;
            onSelect(selection.first);
          },
        ),
      ),
    );
  }
}

/// 五档画质对照列表：把「无/低/中/高/极高」每一档列成一条标准设置行——档名是
/// 标题、「一句话说明 + 显卡要求」是副标题，常驻在档位选择器下方，让用户**选档前**
/// 就能纵向比较各档的画质取舍与 GPU 门槛（用户诉求 2）。
///
/// 当前命中的 [current] 档用选中态表达（行尾对勾 + 标题强调色），不再整行铺底色
/// 做成表格；自定义勾选（current=null）时没有对勾。给了 [onSelect] 时整行可点
/// （与上方分段按钮同一入口，iOS 选择列表 / MD3 单选列表的直觉）。
class VideoShaderTierComparison extends StatelessWidget {
  const VideoShaderTierComparison({
    required this.current,
    this.onSelect,
    super.key,
  });

  /// 当前命中的档（null=自定义勾选，不标记任何行）。
  final VideoShaderTier? current;

  /// 点行选档；null = 纯展示。
  final Future<void> Function(VideoShaderTier tier)? onSelect;

  static IconData _tierIcon(VideoShaderTier tier) {
    switch (tier) {
      case VideoShaderTier.off:
        return Icons.signal_cellular_0_bar;
      case VideoShaderTier.low:
        return Icons.signal_cellular_alt_1_bar;
      case VideoShaderTier.medium:
        return Icons.signal_cellular_alt_2_bar;
      case VideoShaderTier.high:
        return Icons.signal_cellular_alt;
      case VideoShaderTier.ultra:
        return Icons.auto_awesome_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color checkColor = glass
        ? appleColorsOf(context).accent
        : (isEinkTheme(context) ? cs.onSurface : cs.primary);
    final List<VideoShaderTierSpec> specs = shaderTiersFor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < specs.length; i++) ...<Widget>[
          if (glass && i > 0)
            const _AppleSeparator(afterIcon: true),
          Semantics(
            selected: current == specs[i].tier,
            child: AdaptiveSettingsRow(
              key: ValueKey<String>('video-shader-tier-row-${specs[i].tier.name}'),
              title: shaderTierLabel(specs[i].tier),
              subtitle: shaderTierLabelDescription(specs[i].tier),
              icon: _tierIcon(specs[i].tier),
              showIcon: true,
              trailing: current == specs[i].tier
                  ? FushiIcon(Icons.check, color: checkColor)
                  : null,
              onTap: onSelect == null
                  ? null
                  : () => onSelect!(specs[i].tier),
            ),
          ),
        ],
      ],
    );
  }
}
