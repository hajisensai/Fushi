import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/utils.dart';

/// 设置区「漫画 OCR」组的正文（隶属**漫画**设置分类）。
///
/// 内容：默认引擎下拉、内置 OCR 模型状态行（已下载/未下载 + 体积）、下载按钮
/// （进度条 + 可取消）、删除按钮（二次确认）。本地模型只在支持整卷 ONNX 的平台
/// 显示；下方是外部 mokuro CLI 路径设置（仅桌面）。旧的单框 Gemini 配置和 Google
/// Lens 说明段落均不再渲染——Lens 的上传告知由首次使用时的
/// `ensureGoogleLensDisclosure` 同意弹窗承担，设置页不再重复一遍。
///
/// 服务经构造参数注入（不 `ref.read` provider），偏好与外部探测提供可注入默认实现，
/// 故最小 widget 测试注 fake 即可独立编译/通过；真实接线由 `settings_schema_manga_ocr.dart`
/// 从 provider 取服务后构造本 widget。
class MangaOcrSettingsSection extends ConsumerStatefulWidget {
  const MangaOcrSettingsSection({
    required this.service,
    this.probeExternal,
    this.mokuroPathGetter,
    this.mokuroPathSetter,
    this.enginePreferenceGetter,
    this.enginePreferenceSetter,
    this.lensLanguageGetter,
    this.lensLanguageSetter,
    super.key,
  });

  /// 内置 OCR 服务（接口；测试注 fake）。
  final MangaOcrService service;

  /// 外部 mokuro 探测注入口（测试用）：null = 用当前路径真实构造 [ExternalMokuroRunner]。
  final Future<String?> Function(String path)? probeExternal;

  /// 外部 mokuro 路径读取（测试用）：null = 读 [appProvider] 偏好。
  final String Function()? mokuroPathGetter;

  /// 外部 mokuro 路径写入（测试用）：null = 写 [appProvider] 偏好。
  final Future<void> Function(String value)? mokuroPathSetter;

  /// Engine preference is optional for embedders predating the selector.
  /// When omitted the section uses `auto` without touching a provider.
  final String Function()? enginePreferenceGetter;
  final Future<void> Function(String value)? enginePreferenceSetter;

  /// Google Lens 识别语言偏好读写（可选：省略时下拉不出现）。
  final String Function()? lensLanguageGetter;
  final Future<void> Function(String value)? lensLanguageSetter;

  @override
  ConsumerState<MangaOcrSettingsSection> createState() =>
      _MangaOcrSettingsSectionState();
}

class _MangaOcrSettingsSectionState
    extends ConsumerState<MangaOcrSettingsSection> {
  late final TextEditingController _pathCtrl;
  late MangaOcrEnginePreference _enginePreference;
  late String _lensLanguage;

  MangaOcrModelStatus? _status;
  bool _loadingStatus = true;

  // 下载态。
  bool _downloading = false;
  String? _downloadingFile;

  /// 逐文件已收字节（文件名 → 字节）。
  ///
  /// 下载器的事件是**按文件**报进度的（每个文件各自 0→100%），照搬到 UI 上就是
  /// 一根进度条来回跑四趟：用户看到「下了一次又一次」，把 450 MB 的一套模型感知
  /// 成好几个 G（BUG-1732 用户原话）。这里按文件名归并累计，进度条只走一趟，
  /// 并显示「已下 / 总量」的绝对字节，让「到底要下多少」有个准数。
  final Map<String, int> _receivedByFile = <String, int>{};
  StreamSubscription<MangaOcrDownloadEvent>? _downloadSub;

  bool _deleting = false;

  // 外部探测态。
  bool _probing = false;
  String? _probeResult;

  @override
  void initState() {
    super.initState();
    _pathCtrl = TextEditingController(text: _readPath());
    _enginePreference = MangaOcrEnginePreferenceKey.fromKey(
      _readEnginePreference(),
    );
    _lensLanguage = normalizeLensLanguage(widget.lensLanguageGetter?.call());
    if (widget.service.isSupportedPlatform) {
      unawaited(_loadStatus());
    } else {
      _loadingStatus = false;
    }
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _pathCtrl.dispose();
    super.dispose();
  }

  String _readPath() {
    final String Function()? getter = widget.mokuroPathGetter;
    if (getter != null) return getter();
    return ref.read(appProvider).mangaExternalMokuroPath;
  }

  Future<void> _writePath(String value) async {
    final Future<void> Function(String)? setter = widget.mokuroPathSetter;
    if (setter != null) {
      await setter(value);
      return;
    }
    await ref.read(appProvider).setMangaExternalMokuroPath(value);
  }

  String _readEnginePreference() {
    final String Function()? getter = widget.enginePreferenceGetter;
    if (getter != null) return getter();
    return MangaOcrEnginePreference.auto.key;
  }

  Future<void> _writeEnginePreference(
    MangaOcrEnginePreference preference,
  ) async {
    final Future<void> Function(String)? setter = widget.enginePreferenceSetter;
    if (setter != null) {
      await setter(preference.key);
    }
  }

  Future<void> _writeLensLanguage(String language) async {
    await widget.lensLanguageSetter?.call(language);
  }

  Future<void> _loadStatus() async {
    setState(() => _loadingStatus = true);
    MangaOcrModelStatus? status;
    try {
      status = await widget.service.modelStatus();
    } catch (_) {
      status = null;
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _loadingStatus = false;
    });
  }

  /// 全套模型的预期总字节数（清单常量之和）；未知时为 0。
  int get _downloadTotalBytes => _status?.totalBytes ?? 0;

  int get _downloadReceivedBytes =>
      _receivedByFile.values.fold<int>(0, (int a, int b) => a + b);

  void _startDownload() {
    setState(() {
      _downloading = true;
      _downloadingFile = null;
      _receivedByFile.clear();
    });
    _downloadSub = widget.service.downloadModels().listen(
      (MangaOcrDownloadEvent event) {
        if (!mounted) return;
        setState(() {
          _downloadingFile = event.fileName;
          // 同名文件取最新值而不是累加：同一文件会连发多条递增进度事件。
          _receivedByFile[event.fileName] = event.receivedBytes;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _downloadSub = null;
        });
        FushiToast.show(
          msg: t.manga_ocr_download_failed,
          severity: ToastSeverity.error,
        );
      },
      onDone: () async {
        _downloadSub = null;
        if (!mounted) return;
        setState(() => _downloading = false);
        FushiToast.show(
          msg: t.manga_ocr_download_done,
          severity: ToastSeverity.success,
        );
        await _loadStatus();
      },
    );
  }

  Future<void> _cancelDownload() async {
    await _downloadSub?.cancel();
    _downloadSub = null;
    if (!mounted) return;
    setState(() => _downloading = false);
  }

  Future<void> _confirmDelete() async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.manga_ocr_delete_confirm_title),
        content: Text(t.manga_ocr_delete_confirm_message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.manga_ocr_delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    int freed = 0;
    try {
      freed = await widget.service.deleteModels();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    // 报实际释放量而不是干巴巴一句「已删除」：用户抱怨「只删了 450 MB」正是因为
    // 删除完全不回报数字，只能靠自己去看磁盘（BUG-1732）。
    FushiToast.show(
      msg: freed > 0
          ? t.manga_ocr_delete_done_freed(size: _formatBytes(freed))
          : t.manga_ocr_delete_done,
      severity: ToastSeverity.success,
    );
    await _loadStatus();
  }

  Future<void> _detectExternal() async {
    if (_probing) return;
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final String path = _pathCtrl.text.trim();
    await _writePath(path);
    String? version;
    try {
      final Future<String?> Function(String)? probe = widget.probeExternal;
      version = probe != null
          ? await probe(path)
          : await ExternalMokuroRunner(
              configuredPath: path.isEmpty ? null : path,
            ).probe();
    } catch (_) {
      version = null;
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = version != null
          ? t.manga_ocr_external_detected(version: version)
          : t.manga_ocr_external_not_found;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Material 透明层：cupertino 桌面嵌入渲染（BUG-009 R2 路径）下设置正文没有
    // Material 祖先，而本组含 TextField/InkWell 系控件——透明 Material 只补墨水
    // 与文本编辑依赖，不改视觉。
    return Material(
      type: MaterialType.transparency,
      child: _buildBody(theme),
    );
  }

  /// 补齐标准设置行的水平内边距。
  ///
  /// [SettingsCustomItem] 是 `settings_schema_widgets.dart` 的 switch 里**唯一**
  /// 不经过 `AdaptiveSettingsRow*` 的分支，而那 16px 横向 padding 正是由行控件自带
  /// 的。于是本组件的裸内容贴在卡片边（x=0），同一张卡片里的模型状态行与「在线目录
  /// 地址」行却在 x=16——用户看到的「漫画设置左右间距和其他设置不一样」就是这 16px。
  /// 这里由组件自己补上，与制卡/媒体记录/配置方案那几个 body 逃生口的做法一致
  /// （它们靠 `AdaptiveSettingsSection` + `AdaptiveSettingsRow` 天然拿到 16）。
  Widget _inset(Widget child) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: child,
    );
  }

  Widget _buildBody(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _inset(_sectionLabel(theme, t.manga_ocr_section)),
        // 引擎下拉全平台显示：出厂默认已是 Google Lens（会上传页面），把开关关在
        // 桌面里等于让移动端用户无法持久地退回离线引擎。外部 mokuro 是桌面工具，
        // 由下拉项自身 disable，不再靠整块 gating。
        _inset(_buildEnginePreference(theme)),
        if (widget.lensLanguageGetter != null) ...<Widget>[
          const SizedBox(height: 12),
          _inset(_buildLensLanguage(theme)),
        ],
        const SizedBox(height: 12),
        if (widget.service.isSupportedPlatform)
          _buildLocalModelArea(theme)
        else
          _inset(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                t.manga_ocr_unsupported,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        // 外部 mokuro CLI 是桌面工具，仅桌面显示。
        if (isDesktopPlatform) ...<Widget>[
          const SizedBox(height: 16),
          _inset(_buildExternalBlock(theme)),
        ],
      ],
    );
  }

  /// 引擎选项表：标签 + **取舍说明** + 可用性，一处定义。
  ///
  /// 说明不是装饰：几个引擎的差别全在「要不要联网 / 会不会上传页面图 / 质量高低 /
  /// 要不要下几百 MB 模型」上，而下拉里只有五个裸名字时，用户没有任何依据挑
  /// （用户原话：这里说一下每个的特点）。取舍写在选项自己身上，别指望用户去翻
  /// 文档或试错。
  ///
  /// 平台不适用的项**保留在列表里**只置灰（不裁项）：裁掉会让「已存 external_mokuro
  /// 的偏好」在移动端找不到匹配 value 而触发 Dropdown 断言。
  List<_EngineOption> _engineOptions() {
    return <_EngineOption>[
      _EngineOption(
        preference: MangaOcrEnginePreference.auto,
        label: t.manga_ocr_engine_auto,
        description: t.manga_ocr_engine_auto_desc,
        enabled: true,
      ),
      _EngineOption(
        preference: MangaOcrEnginePreference.localOnnx,
        label: t.manga_ocr_engine_local_onnx,
        description: t.manga_ocr_engine_local_onnx_desc,
        enabled: widget.service.isSupportedPlatform,
      ),
      _EngineOption(
        preference: MangaOcrEnginePreference.googleLens,
        label: t.manga_ocr_engine_google_lens,
        description: t.manga_ocr_engine_google_lens_desc,
        enabled: true,
      ),
      _EngineOption(
        preference: MangaOcrEnginePreference.externalMokuro,
        label: t.manga_ocr_engine_external,
        description: t.manga_ocr_engine_external_desc,
        enabled: isDesktopPlatform,
      ),
      // 互联「配对主机代跑」：服务端/客户端链路早已完整（/api/ocr/job*），此前
      // 只是没进偏好枚举，导致它永远只能被 auto 兜底顺序选中、无法显式指定。
      // 移动端没有本地 ONNX 时这是唯一可用的整卷引擎。
      _EngineOption(
        preference: MangaOcrEnginePreference.pairedHost,
        label: t.manga_remote_ocr_engine,
        description: t.manga_ocr_engine_paired_host_desc,
        enabled: true,
      ),
    ];
  }

  Widget _buildEnginePreference(ThemeData theme) {
    final List<_EngineOption> options = _engineOptions();
    return DropdownButtonFormField<MangaOcrEnginePreference>(
      key: const ValueKey<String>('manga_ocr_default_engine'),
      initialValue: _enginePreference,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: t.manga_ocr_default_engine,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      // 闭合态只显示单行标签：说明是给「挑的时候」看的，收起后再占两行只会把
      // 设置行撑高。
      selectedItemBuilder: (BuildContext context) => <Widget>[
        for (final _EngineOption option in options)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(option.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      items: <DropdownMenuItem<MangaOcrEnginePreference>>[
        for (final _EngineOption option in options)
          DropdownMenuItem<MangaOcrEnginePreference>(
            value: option.preference,
            enabled: option.enabled,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(option.label),
                Text(
                  option.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
      // 两行项比默认 kMinInteractiveDimension 高，不给足高度会 overflow。
      itemHeight: null,
      onChanged: (MangaOcrEnginePreference? value) {
        if (value == null) return;
        setState(() => _enginePreference = value);
        unawaited(_writeEnginePreference(value));
      },
    );
  }

  /// Google Lens 识别语言（默认/本地书兜底）。在线阅读优先用源声明的语言，
  /// 只有源语言未知时才回退到这里；本地漫画整卷 OCR 直接用此值。
  Widget _buildLensLanguage(ThemeData theme) {
    final List<DropdownMenuItem<String>> items = <DropdownMenuItem<String>>[
      for (final (String tag, String label) in kGoogleLensLanguageOptions)
        DropdownMenuItem<String>(value: tag, child: Text(label)),
      if (!kGoogleLensLanguageOptions
          .any(((String, String) option) => option.$1 == _lensLanguage))
        DropdownMenuItem<String>(
          value: _lensLanguage,
          child: Text(_lensLanguage),
        ),
    ];
    return DropdownButtonFormField<String>(
      key: const ValueKey<String>('manga_ocr_lens_language'),
      initialValue: _lensLanguage,
      decoration: InputDecoration(
        labelText: t.manga_ocr_lens_language_label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: items,
      onChanged: (String? value) {
        if (value == null) return;
        setState(() => _lensLanguage = value);
        unawaited(_writeLensLanguage(value));
      },
    );
  }

  /// 当前引擎偏好是否真的会用到本地 ONNX 模型。
  ///
  /// `auto` 会在离线优先的兜底顺序里挑到本地模型，所以算「用得到」；显式选了
  /// Lens / 外部 mokuro / 配对主机的，本机一个字节都不需要。
  bool get _localModelsUsedByEngine =>
      _enginePreference == MangaOcrEnginePreference.auto ||
      _enginePreference == MangaOcrEnginePreference.localOnnx;

  /// 本地模型区：**按当前引擎决定形态**。
  ///
  /// 修的是「我选的是 Google Lens，这儿怎么还让我下模型」（用户原话）——原先这块
  /// 只受平台闸门控制，跟引擎选择完全脱钩，于是一个永远用不到本地模型的用户被
  /// 一直劝着下 450 MB。三种形态：
  /// - 引擎用得到（auto / 本地 ONNX）→ 完整块：状态 + 下载/删除。
  /// - 引擎用不到但**磁盘上还留着文件** → 只给「用不到 + 占用多少 + 删除」，
  ///   这正是「应该支持删除 ocr 模型」的落点：换了引擎之后那几百 MB 得能清掉。
  /// - 引擎用不到且磁盘干净 → 整块不渲染，不再劝下载。
  Widget _buildLocalModelArea(ThemeData theme) {
    if (_loadingStatus) {
      return _inset(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(),
        ),
      );
    }
    if (_localModelsUsedByEngine) {
      return _buildModelBlock(theme);
    }
    final MangaOcrModelStatus? status = _status;
    if (status == null || !status.hasAnyFiles) {
      return const SizedBox.shrink();
    }
    return _buildOrphanModelBlock(theme, status);
  }

  /// 引擎用不到、但磁盘上还占着的本地模型：说清楚 + 给删除。
  Widget _buildOrphanModelBlock(ThemeData theme, MangaOcrModelStatus status) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.manga_ocr_model_unused_by_engine,
          subtitle: t.manga_ocr_model_disk_usage(
            size: _formatBytes(status.diskBytes),
          ),
          icon: Icons.folder_off_outlined,
          showIcon: true,
        ),
        const SizedBox(height: 8),
        _inset(
          Align(
            alignment: Alignment.centerLeft,
            child: _deleteButton(),
          ),
        ),
      ],
    );
  }

  Widget _buildModelBlock(ThemeData theme) {
    final MangaOcrModelStatus? status = _status;
    final bool ready = status?.allReady ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: ready
              ? t.manga_ocr_model_status_ready
              : t.manga_ocr_model_status_missing,
          subtitle: _modelSizeSubtitle(status),
          icon: ready ? Icons.check_circle_outline : Icons.download_outlined,
          showIcon: true,
        ),
        if (_downloading) ...<Widget>[
          const SizedBox(height: 8),
          _inset(LinearProgressIndicator(value: _downloadProgressValue)),
          const SizedBox(height: 4),
          if (_downloadingFile != null)
            _inset(
              Text(
                t.manga_ocr_downloading_file(file: _downloadingFile!),
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (_downloadTotalBytes > 0)
            _inset(
              Text(
                t.manga_ocr_download_total_progress(
                  done: _formatBytes(_downloadReceivedBytes),
                  total: _formatBytes(_downloadTotalBytes),
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          _inset(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _cancelDownload,
                child: Text(t.dialog_cancel),
              ),
            ),
          ),
        ] else ...<Widget>[
          const SizedBox(height: 8),
          _inset(
            Align(
              alignment: Alignment.centerLeft,
              child: ready
                  ? _deleteButton()
                  : FilledButton.icon(
                      onPressed: _startDownload,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(t.manga_ocr_download),
                    ),
            ),
          ),
          // 模型不全但磁盘上有残留（中断的 `.part`、换档后的遗留档）时，除了
          // 「继续下载」也得能直接清掉——否则那几百 MB 在 UI 上无处可删。
          if (!ready && (status?.hasAnyFiles ?? false)) ...<Widget>[
            const SizedBox(height: 4),
            _inset(
              Align(
                alignment: Alignment.centerLeft,
                child: _deleteButton(),
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// 体积副标题：已占多少 + 还需下多少，两者都按真实数字给。
  ///
  /// 旧实现是 `已下载 / 清单总量` 这种双数字拼接，而「已下载」只累加清单内已就绪
  /// 文件——`.part` 残留与遗留档一律看不见，用户于是遇到「显示 450 MB、删掉后
  /// 磁盘却少了别的数」（BUG-1732）。
  String? _modelSizeSubtitle(MangaOcrModelStatus? status) {
    if (status == null) {
      return null;
    }
    final String? usage = status.hasAnyFiles
        ? t.manga_ocr_model_disk_usage(size: _formatBytes(status.diskBytes))
        : null;
    if (status.allReady) {
      return usage;
    }
    final String? needed = status.totalBytes > 0
        ? t.manga_ocr_model_download_size(
            size: _formatBytes(status.totalBytes),
          )
        : null;
    final String joined =
        <String?>[usage, needed].whereType<String>().join(' · ');
    return joined.isEmpty ? null : joined;
  }

  /// 总体下载进度（0~1）；总量未知时返回 null 走不确定进度条。
  double? get _downloadProgressValue {
    final int total = _downloadTotalBytes;
    if (total <= 0) {
      return null;
    }
    return (_downloadReceivedBytes / total).clamp(0.0, 1.0);
  }

  Widget _deleteButton() {
    return OutlinedButton.icon(
      onPressed: _deleting ? null : _confirmDelete,
      icon: _deleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.delete_outline, size: 18),
      label: Text(t.manga_ocr_delete),
    );
  }

  Widget _buildExternalBlock(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _pathCtrl,
          decoration: InputDecoration(
            labelText: t.manga_ocr_external_cli_label,
            hintText: t.manga_ocr_external_cli_hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (String v) => unawaited(_writePath(v.trim())),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _probing ? null : _detectExternal,
              icon: _probing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_outlined, size: 18),
              label: Text(t.manga_ocr_external_detect),
            ),
            if (_probeResult != null) ...<Widget>[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _probeResult!,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }

  static String _formatBytes(int bytes) => FushiByteFormat.bytes(bytes);
}

/// 引擎下拉的一项：偏好值 + 标签 + 取舍说明 + 本平台是否可用。
class _EngineOption {
  const _EngineOption({
    required this.preference,
    required this.label,
    required this.description,
    required this.enabled,
  });

  final MangaOcrEnginePreference preference;
  final String label;

  /// 一句话取舍：联网/上传/质量/下载量，用户据此挑引擎。
  final String description;

  final bool enabled;
}
