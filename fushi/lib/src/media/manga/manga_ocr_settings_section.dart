import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_panel_kit.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/src/ocr/manga_ocr_model_import.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi/utils.dart';

/// [MangaOcrSettingsSection] 的版式：设置页（M3E 分组：识别引擎选择行、性能、
/// 大模型增强、本地模型状态卡、外部工具）或阅读器设置侧板（引擎单选卡片组平铺）。
/// 只换呈现，读写的偏好与回调完全相同。
enum MangaOcrSettingsPresentation { settingsPage, readerPanel }

/// 设置区「漫画 OCR」组的正文（隶属**漫画**设置分类）。
///
/// 内容：默认引擎（本机模型直接作为引擎项列出）、Lens 识别语言、并行任务、
/// 大模型识别档位、本机模型状态卡（已下载 / 需下载 + 体积 + 波浪进度 + 下载 /
/// 导入 / 删除）、外部 mokuro CLI 路径（仅桌面）。下载归全局
/// [MangaOcrModelDownloads] 所有，离开本页照常在后台继续。Lens 的上传告知由首次
/// 使用时的 `ensureGoogleLensDisclosure` 同意弹窗承担，设置页不再重复一遍。
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
    this.parallelTasksGetter,
    this.parallelTasksSetter,
    this.localModelGetter,
    this.localModelSetter,
    this.lensLanguageGetter,
    this.lensLanguageSetter,
    this.modelsDirProvider,
    this.modelImporter,
    this.pickImportPaths,
    this.systemOcrRunner,
    this.pairedHostModelGetter,
    this.pairedHostModelSetter,
    this.remoteRunner,
    this.aiModeGetter,
    this.aiModeSetter,
    this.aiProviderReady,
    this.openAiSettings,
    this.presentation = MangaOcrSettingsPresentation.settingsPage,
    super.key,
  });

  /// 版式（见 [MangaOcrSettingsPresentation]）。
  final MangaOcrSettingsPresentation presentation;

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

  /// 桌面跨书任务并发：0 自动，1～4 手动。
  final int Function()? parallelTasksGetter;
  final Future<void> Function(int value)? parallelTasksSetter;

  final String Function()? localModelGetter;
  final Future<void> Function(String value)? localModelSetter;

  /// Google Lens 识别语言偏好读写（可选：省略时下拉不出现）。
  final String Function()? lensLanguageGetter;
  final Future<void> Function(String value)? lensLanguageSetter;

  /// 手动导入的落地目录；null = 真实模型目录。
  final Future<Directory> Function()? modelsDirProvider;

  /// 手动导入器；null = 真实清单的 [MangaOcrModelImporter]。
  final MangaOcrModelImporter? modelImporter;

  /// 导入来源选择注入口（测试用）：`folderMode` 为真表示用户选了「选择文件夹」。
  /// null = 走真实系统选择器。返回 null / 空表示用户取消。
  final Future<List<String>?> Function(bool folderMode)? pickImportPaths;

  /// 系统 OCR 可用性探测；null = 走真实平台通道。
  final SystemOcrMangaRunner? systemOcrRunner;

  /// 「Fushi 互联服务端」点名的服务端模型（空串 = 服务端默认）。省略时服务端只有
  /// 一项、跟着服务端自己的选择走。
  final String Function()? pairedHostModelGetter;
  final Future<void> Function(String value)? pairedHostModelSetter;

  /// 探测已配对服务端有哪些模型；null = 不列服务端模型。
  final MangaOcrRemoteRunner? remoteRunner;

  /// 大模型识别档位（`MangaAiOcrMode.storageKey`）读写；省略时下拉不出现。
  final String Function()? aiModeGetter;
  final Future<void> Function(String value)? aiModeSetter;

  /// 「设置 › AI」里给漫画 OCR 解析到了能用的提供商（含默认提供商）。档位开着
  /// 却没有提供商时，下拉下方提示「目前不会发送任何内容」并给入口。
  final bool Function()? aiProviderReady;

  /// 打开「设置 › AI」；null = 不显示入口。返回的 Future 在用户从那一页回来时
  /// 完成：回来后重算「有没有提供商」（用户多半就是去指派提供商的）。
  final Future<void> Function(BuildContext context)? openAiSettings;

  @override
  ConsumerState<MangaOcrSettingsSection> createState() =>
      _MangaOcrSettingsSectionState();
}

class _MangaOcrSettingsSectionState
    extends ConsumerState<MangaOcrSettingsSection> {
  late final TextEditingController _pathCtrl;
  late MangaOcrEnginePreference _enginePreference;
  late int _parallelTasks;
  late MangaOcrLocalModel _localModel;
  late String _lensLanguage;
  late MangaAiOcrMode _aiMode;

  /// 当前点名的服务端模型；null = 服务端默认。
  String? _pairedHostModel;

  /// 已配对服务端报上来的可点名模型（探测完成前为空）。
  List<MangaOcrRemoteModel> _hostModels = const <MangaOcrRemoteModel>[];

  MangaOcrModelStatus? _status;
  bool _loadingStatus = true;
  int _statusRequest = 0;

  /// 下载态归全局登记表（后台下载）：本页只是观察者，dispose 不取消下载。
  ///
  /// 进度按文件名归并累计（BUG-1732：逐文件照搬会让进度条来回跑好几趟），由
  /// 登记表算好；这里只读快照。
  late final MangaOcrModelDownloads _downloads;

  /// 上一帧当前模型是否在下载：从「在下」变成「不在下」时重读磁盘状态。
  bool _wasDownloading = false;

  bool get _downloading => _downloads.isActive(_localModel);

  MangaOcrModelDownloadProgress? get _progress =>
      _downloads.progressOf(_localModel);

  String? get _downloadingFile => _progress?.currentFile;

  bool _deleting = false;

  /// 手动导入态（导入期间禁用下载/删除，避免两条路径同时动同一批文件）。
  bool _importing = false;

  /// 本机有没有系统自带 OCR。默认 false：未探测出结果之前不假装可用。
  bool _systemOcrAvailable = false;

  // 外部探测态。
  bool _probing = false;
  String? _probeResult;

  /// 最近一次探测是否找到了 mokuro（决定结果提示用成功色还是警告色）。
  bool _probeFound = false;

  /// 设置页「本地模型」分组在当前引擎用不到时是否展开详情（默认收起）。
  bool _modelDetailsExpanded = false;

  @override
  void initState() {
    super.initState();
    _pathCtrl = TextEditingController(text: _readPath());
    _enginePreference = MangaOcrEnginePreferenceKey.fromKey(
      _readEnginePreference(),
    );
    _lensLanguage = normalizeLensLanguage(widget.lensLanguageGetter?.call());
    _aiMode = MangaAiOcrMode.fromStorageKey(widget.aiModeGetter?.call());
    _parallelTasks = (widget.parallelTasksGetter?.call() ?? 0).clamp(0, 4);
    _localModel = MangaOcrLocalModel.forPlatform(
      widget.localModelGetter?.call() ?? kDefaultMangaOcrLocalModel.key,
    );
    _downloads = ref.read(mangaOcrModelDownloadsProvider);
    _wasDownloading = _downloading;
    _downloads.addListener(_onDownloadsChanged);
    // BUG-1780：这个位现在就是「本机能不能跑本地 ONNX 推理」（ORT native 可用性），
    // 不再是一份独立的平台白名单。它为真的每一端都要加载模型状态——整卷 / 点击 /
    // 框选区域重识别走的都是同一个本地 ONNX 引擎，闸门本来就是 ORT 可用性。
    if (widget.service.isSupportedPlatform) {
      unawaited(_loadStatus());
    } else {
      _loadingStatus = false;
    }
    unawaited(_probeSystemOcr());
    final String hostModel = widget.pairedHostModelGetter?.call() ?? '';
    _pairedHostModel = hostModel.isEmpty ? null : hostModel;
    if (widget.pairedHostModelGetter != null && widget.remoteRunner != null) {
      unawaited(_probeHostModels());
    }
  }

  Future<void> _probeHostModels() async {
    MangaOcrRemoteTarget? target;
    try {
      target = await widget.remoteRunner!.probe();
    } catch (_) {
      // 探测失败就只列「服务端默认」与当前已选那项，选择照样可用。
      target = null;
    }
    if (!mounted || target == null) return;
    setState(() => _hostModels = target!.capability.models);
  }

  @override
  void didUpdateWidget(MangaOcrSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _localModel = MangaOcrLocalModel.forPlatform(
      widget.localModelGetter?.call() ?? kDefaultMangaOcrLocalModel.key,
    );
    _wasDownloading = _downloading;
    if (!identical(widget.service, oldWidget.service)) {
      _status = null;
      unawaited(_loadStatus());
    }
  }

  @override
  void dispose() {
    // 只摘监听、不取消下载：下载在后台继续（完成提示由登记表弹）。
    _downloads.removeListener(_onDownloadsChanged);
    _pathCtrl.dispose();
    super.dispose();
  }

  void _onDownloadsChanged() {
    if (!mounted) return;
    final bool downloading = _downloading;
    final bool finished = _wasDownloading && !downloading;
    _wasDownloading = downloading;
    setState(() {});
    if (finished) unawaited(_loadStatus());
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
    // 回退值必须与偏好仓库的出厂默认同源（BUG-1780）：这里曾经硬写 `auto`，
    // 而生产默认是 `google_lens`，两者分叉让 UI 守卫恒绿——测试永远在跑一条
    // 用户碰不到的分支。
    return kDefaultMangaOcrEnginePreference.key;
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

  /// 探测系统 OCR 是否可用（决定下拉里那一项是否置灰）。
  ///
  /// 失败一律当成不可用：这个探测只是决定一个选项灰不灰，为它弹错误提示纯属
  /// 噪音。
  Future<void> _probeSystemOcr() async {
    bool available = false;
    try {
      available = await (widget.systemOcrRunner ?? SystemOcrMangaService())
          .isAvailable();
    } catch (_) {
      available = false;
    }
    if (!mounted) return;
    setState(() => _systemOcrAvailable = available);
  }

  Future<void> _loadStatus() async {
    final int request = ++_statusRequest;
    setState(() => _loadingStatus = true);
    MangaOcrModelStatus? status;
    try {
      status = await widget.service.modelStatus();
    } catch (_) {
      status = null;
    }
    if (!mounted || request != _statusRequest) return;
    setState(() {
      _status = status;
      _loadingStatus = false;
    });
  }

  /// 全套模型的预期总字节数（清单常量之和）；未知时为 0。
  int get _downloadTotalBytes => _status?.totalBytes ?? 0;

  int get _downloadReceivedBytes => _progress?.receivedBytes ?? 0;

  void _startDownload() {
    if (_importing) return;
    _downloads.start(_localModel, widget.service);
  }

  Future<void> _cancelDownload() => _downloads.cancel(_localModel);

  Future<void> _confirmDelete() async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.manga_ocr_delete_confirm_title,
      message: t.manga_ocr_delete_confirm_message,
      icon: FushiIcons.delete,
      confirmLabel: t.manga_ocr_delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
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

  // ── 手动导入模型 ─────────────────────────────────────────────────────
  //
  // 470 MB 走 huggingface 直连，在部分网络下是「连不上」而不是「慢」。下载器的
  // 镜像回退覆盖大多数这类用户，这条路径是给连镜像也不通的人留的最后一扇门：
  // 文件他们能用别的手段拿到，缺的只是把文件交给 app 的入口。

  Future<Directory> _modelsDir() {
    final Future<Directory> Function()? provider = widget.modelsDirProvider;
    if (provider != null) {
      return provider();
    }
    return _localModel.modelsDirectory();
  }

  /// 导入入口对话框：**先说要哪些文件，再给选择器**。
  ///
  /// 顺序不能反。用户点进来时最缺的信息不是「怎么选文件」，而是「到底要哪几个
  /// 文件、各多大」；直接弹系统选择器等于让人回去猜，猜错了就是又一次几百 MB
  /// 的白费功夫。
  Future<void> _showImportDialog() async {
    final bool? folderMode = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final ThemeData dialogTheme = Theme.of(ctx);
        return FushiAlertDialog(
          title: Text(t.manga_ocr_import_title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(t.manga_ocr_import_intro),
                const SizedBox(height: 12),
                for (final MangaOcrModelFile model in _localModel.manifest)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${model.fileName} · ${_formatBytes(model.expectedBytes)}',
                      style: dialogTheme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FushiTextButton.icon(
                    onPressed: () => unawaited(_copyModelUrls()),
                    icon: const FushiIcon(FushiIcons.link, size: 18),
                    label: Text(t.manga_ocr_import_copy_urls),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            FushiTextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.dialog_cancel),
            ),
            FushiTextButton(
              key: const ValueKey<String>('manga_ocr_import_pick_files'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.manga_ocr_import_pick_files),
            ),
            FushiFilledButton(
              key: const ValueKey<String>('manga_ocr_import_pick_folder'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.manga_ocr_import_pick_folder),
            ),
          ],
        );
      },
    );
    if (folderMode == null || !mounted) return;
    await _runImport(folderMode: folderMode);
  }

  /// 复制全部候选下载链接（主源 + 镜像）。
  ///
  /// 给的是候选序列而不是单条主源：会走到这个入口的用户，多半正是主源连不上的
  /// 那批人，只给主源等于什么都没给。
  Future<void> _copyModelUrls() async {
    final StringBuffer buffer = StringBuffer();
    for (final MangaOcrModelFile model in _localModel.manifest) {
      for (final String url in mangaOcrModelUrlCandidates(model)) {
        buffer.writeln(url);
      }
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    FushiToast.show(
      msg: t.manga_ocr_import_urls_copied,
      severity: ToastSeverity.success,
    );
  }

  Future<void> _runImport({required bool folderMode}) async {
    if (_importing || _downloading) return;
    final List<String>? paths = await _pickImportPaths(folderMode);
    if (paths == null || paths.isEmpty || !mounted) return;

    setState(() => _importing = true);
    MangaOcrModelImportResult? result;
    Object? failure;
    try {
      final MangaOcrModelImporter importer =
          widget.modelImporter ??
          MangaOcrModelImporter(manifest: _localModel.manifest);
      result = await importer.import(
        sourcePaths: paths,
        targetDir: await _modelsDir(),
      );
    } on Object catch (error) {
      failure = error;
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    if (result == null) {
      FushiToast.show(
        msg: '${t.manga_ocr_import_failed}: $failure',
        severity: ToastSeverity.error,
      );
      return;
    }
    _reportImport(result);
    await _loadStatus();
  }

  Future<List<String>?> _pickImportPaths(bool folderMode) async {
    final Future<List<String>?> Function(bool)? injected =
        widget.pickImportPaths;
    if (injected != null) {
      return injected(folderMode);
    }
    if (folderMode) {
      // 安卓走 SAF 真实路径封装：file_picker 的 tree URI 串喂不进 dart:io。
      final String? dir = await pickRealDirectoryPath(
        context: context,
        appModel: ref.read(appProvider),
      );
      return dir == null ? null : <String>[dir];
    }
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    if (picked == null) {
      return null;
    }
    return picked.files
        .map((PlatformFile file) => file.path)
        .whereType<String>()
        .toList();
  }

  /// 把导入结果讲清楚：**成功了几个、为什么拒了、还差几个**。
  ///
  /// 一条 toast 说完而不是弹三次：这三件事对用户是同一个答案的三个部分，拆开
  /// 只会让人看完最后一条忘了第一条。
  void _reportImport(MangaOcrModelImportResult result) {
    final List<String> lines = <String>[];
    if (result.imported.isNotEmpty) {
      lines.add(t.manga_ocr_import_done(count: result.imported.length));
    }
    if (result.matchedNothing) {
      lines.add(t.manga_ocr_import_matched_nothing);
    }
    for (final MangaOcrModelImportRejection rejection in result.rejected) {
      if (rejection.reason != MangaOcrModelImportRejectReason.sizeMismatch) {
        continue;
      }
      lines.add(
        t.manga_ocr_import_size_mismatch(
          file: rejection.source,
          expected: _formatBytes(rejection.expectedBytes ?? 0),
          actual: _formatBytes(rejection.actualBytes ?? 0),
        ),
      );
    }
    if (!result.allReady && !result.matchedNothing) {
      lines.add(
        t.manga_ocr_import_still_missing(count: result.stillMissing.length),
      );
    }
    if (lines.isEmpty) {
      return;
    }
    FushiToast.show(
      msg: lines.join('\n'),
      severity: result.allReady
          ? ToastSeverity.success
          : (result.changed ? ToastSeverity.warning : ToastSeverity.error),
    );
  }

  /// 「导入本地模型」按钮：下载中/导入中禁用（两条路径会动同一批文件）。
  /// 两种版式都在状态卡里与主按钮成组，统一用描边按钮。
  Widget _importButton() {
    final VoidCallback? onPressed = (_importing || _downloading)
        ? null
        : () => unawaited(_showImportDialog());
    final Widget icon = _importing
        ? const SizedBox.square(
            dimension: 16,
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          )
        : const FushiIcon(FushiIcons.importFile, size: 18);
    final Widget label =
        Text(_importing ? t.manga_ocr_import_running : t.manga_ocr_import);
    return FushiOutlinedButton.icon(
      key: const ValueKey<String>('manga_ocr_import_button'),
      onPressed: onPressed,
      icon: icon,
      label: label,
    );
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
      _probeFound = version != null;
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
      child:
          widget.presentation == MangaOcrSettingsPresentation.readerPanel
              ? _buildPanelBody(theme)
              : _buildBody(theme),
    );
  }

  /// 设置页版式（M3E）：按任务分组的分段卡片列表——识别引擎 / 性能 / 大模型增强 /
  /// 本地模型 / 外部工具。说明一律收进行的 supporting text 或 info，不再平铺整段
  /// 长行；宽屏（≥ [_kWideBreakpoint]）把「性能」与「大模型增强」并排。各分组
  /// 错峰进场（墨水屏 / 减弱动态效果下由共享组件归零）。
  Widget _buildBody(ThemeData theme) {
    final bool showParallel =
        isDesktopPlatform && widget.parallelTasksGetter != null;
    final bool showAi = widget.aiModeGetter != null;
    final Widget engine = MangaPanelGroup(
      title: t.manga_reader_group_ocr_engine,
      children: <Widget>[
        _buildEngineRow(theme),
        if (widget.lensLanguageGetter != null) _buildPanelLensLanguage(),
      ],
    );
    final Widget performance = MangaPanelGroup(
      title: t.manga_ocr_group_performance,
      children: <Widget>[if (showParallel) _buildPanelParallelTasks()],
    );
    final Widget ai = MangaPanelGroup(
      title: t.manga_ocr_group_ai,
      children: <Widget>[if (showAi) _buildPanelAiMode(theme)],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= _kWideBreakpoint && showParallel && showAi;
        final List<Widget> blocks = <Widget>[
          engine,
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: performance),
                const SizedBox(width: 16),
                Expanded(child: ai),
              ],
            )
          else ...<Widget>[performance, ai],
          _buildSettingsModelGroup(theme),
          // 外部 mokuro CLI 是桌面工具，仅桌面显示。
          if (isDesktopPlatform)
            MangaPanelGroup(
              title: t.manga_ocr_group_external_tools,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: _buildPanelExternal(theme),
                ),
              ],
            ),
        ];
        return FushiEntranceScope(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final (int index, Widget block) in blocks.indexed)
                FushiStaggeredEntrance(index: index, child: block),
            ],
          ),
        );
      },
    );
  }

  /// 「性能」与「大模型增强」并排的最小宽度。
  static const double _kWideBreakpoint = 840;

  /// 引擎选项表：标签 + **取舍说明** + 可用性，一处定义。
  ///
  /// 说明不是装饰：几个引擎的差别全在「要不要联网 / 会不会上传页面图 / 质量高低 /
  /// 要不要下几百 MB 模型」上，而下拉里只有五个裸名字时，用户没有任何依据挑
  /// （用户原话：这里说一下每个的特点）。取舍写在选项自己身上，别指望用户去翻
  /// 文档或试错。
  ///
  /// 平台不适用的项**保留在列表里**只置灰（不裁项）：裁掉会让「已存 external_mokuro
  /// 的偏好」在移动端找不到对应项，引擎行与单选卡片组都显示不出当前选择。
  List<_EngineOption> _engineOptions() {
    return <_EngineOption>[
      _EngineOption(
        preference: MangaOcrEnginePreference.auto,
        label: t.manga_ocr_engine_auto,
        description: t.manga_ocr_engine_auto_desc,
        enabled: true,
      ),
      // 本机模型逐个列成引擎项。以前这里只有一项「本地 ONNX」，具体用哪个模型
      // 另起一个「本机 OCR 模型」下拉——两个下拉讲的是同一个选择，用户看到的是
      // 「默认引擎」和「本机模型」重复。宿主没接模型偏好时退回单项。
      if (widget.localModelGetter == null)
        _EngineOption(
          preference: MangaOcrEnginePreference.localOnnx,
          label: t.manga_ocr_engine_local_onnx,
          description: t.manga_ocr_engine_local_onnx_desc,
          enabled: widget.service.isSupportedPlatform,
        )
      else
        // 逐列 CTC 五端都能跑，Baberu 只在 Windows 列出
        // （[MangaOcrLocalModel.availableOnAllPlatforms]）。
        for (final MangaOcrLocalModel model in platformMangaOcrLocalModels())
          _EngineOption(
            preference: MangaOcrEnginePreference.localOnnx,
            localModel: model,
            label: t.manga_ocr_engine_local_model(
              model: localModelLabel(model),
            ),
            description: localModelDescription(model),
            enabled: widget.service.isSupportedPlatform,
          ),
      // 设备自带识别：装完即用、零下载、零上传。排在本地模型之后是因为它对
      // 竖排气泡和手写体明显更弱——描述里如实写出来，别让用户以为捡到便宜。
      // 与其他项同构：恒保留、由 _systemOcrAvailable 决定是否置灰。
      _EngineOption(
        preference: MangaOcrEnginePreference.systemOcr,
        label: t.manga_ocr_engine_system,
        description: t.manga_ocr_engine_system_desc,
        enabled: _systemOcrAvailable,
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
      // 手机上本地整卷虽已可用（BUG-1780），但那是「挂着跑几十分钟」的量级；
      // 把重活推给局域网里的桌面仍然是移动端最实用的选择。
      _EngineOption(
        preference: MangaOcrEnginePreference.pairedHost,
        label: t.manga_remote_ocr_engine,
        description: t.manga_ocr_engine_paired_host_desc,
        enabled: true,
      ),
      // 服务端的模型也逐个列成引擎项（与本机模型同构）：手机上点名让电脑用哪个
      // 模型跑，不必跑去服务端改它自己的选择。列的是服务端报上来的；探测还没回来
      // 或服务端离线时，当前已选那项照样保留，免得下拉找不到当前值。
      if (widget.pairedHostModelGetter != null)
        for (final String key in _pairedHostModelKeys())
          _EngineOption(
            preference: MangaOcrEnginePreference.pairedHost,
            hostModel: key,
            label: t.manga_ocr_engine_paired_host_model(
              model: _hostModelLabel(key),
            ),
            description: _hostModelReady(key) == false
                ? '${_hostModelDescription(key)}\n'
                      '${t.manga_ocr_engine_paired_host_model_missing}'
                : _hostModelDescription(key),
            enabled: true,
          ),
    ];
  }

  List<String> _pairedHostModelKeys() => <String>[
    for (final MangaOcrRemoteModel model in _hostModels) model.key,
    if (_pairedHostModel != null &&
        !_hostModels.any((MangaOcrRemoteModel m) => m.key == _pairedHostModel))
      _pairedHostModel!,
  ];

  /// 服务端没报这个模型时为 null（未知），报了就是它的就绪态。
  bool? _hostModelReady(String key) {
    for (final MangaOcrRemoteModel model in _hostModels) {
      if (model.key == key) return model.ready;
    }
    return null;
  }

  static MangaOcrLocalModel? _knownModel(String key) {
    for (final MangaOcrLocalModel model in MangaOcrLocalModel.values) {
      if (model.key == key) return model;
    }
    return null;
  }

  String _hostModelLabel(String key) {
    final MangaOcrLocalModel? model = _knownModel(key);
    return model == null ? key : localModelLabel(model);
  }

  String _hostModelDescription(String key) {
    final MangaOcrLocalModel? model = _knownModel(key);
    return model == null
        ? t.manga_ocr_engine_paired_host_desc
        : localModelDescription(model);
  }

  /// 下拉当前值：本机 ONNX 带上具体模型，其余就是引擎偏好本身。
  _EngineChoice get _currentChoice => _EngineChoice(
    _enginePreference,
    _enginePreference == MangaOcrEnginePreference.localOnnx &&
            widget.localModelGetter != null
        ? _localModel
        : null,
    hostModel: _enginePreference == MangaOcrEnginePreference.pairedHost
        ? _pairedHostModel
        : null,
  );

  Future<void> _selectEngine(_EngineChoice choice) async {
    final MangaOcrLocalModel? model = choice.localModel;
    // 先落模型再落引擎：服务 provider 跟着模型偏好换实例，引擎偏好一变阅读器
    // 就可能开跑，那时模型必须已经是新的。
    if (model != null && model != _localModel) {
      await widget.localModelSetter?.call(model.key);
      if (!mounted) return;
      setState(() => _localModel = model);
      _wasDownloading = _downloading;
    }
    if (choice.preference == MangaOcrEnginePreference.pairedHost &&
        choice.hostModel != _pairedHostModel) {
      await widget.pairedHostModelSetter?.call(choice.hostModel ?? '');
      if (!mounted) return;
      setState(() => _pairedHostModel = choice.hostModel);
    }
    if (!mounted) return;
    setState(() => _enginePreference = choice.preference);
    await _writeEnginePreference(choice.preference);
  }

  /// 默认引擎选择行：当前引擎的图标 + 名称与一句取舍作 supporting text，点按
  /// 从底部弹出带图标 / 说明的单选卡片组。不可用的引擎在卡片组里置灰（不裁项：
  /// 已存的偏好在别的平台上仍要能显示）。
  Widget _buildEngineRow(ThemeData theme) {
    final List<_EngineOption> options = _engineOptions();
    final _EngineChoice selected = _currentChoice;
    _EngineOption? current;
    for (final _EngineOption option in options) {
      if (option.choice == selected) current = option;
    }
    // 导入 / 删除期间锁住：两者都按当前模型的目录动文件，中途换模型会让结果
    // 落到另一个模型的状态上。下载不锁——它按模型归属全局登记表，换走了照跑。
    final bool locked = _importing || _deleting;
    return AdaptiveSettingsRow(
      key: const ValueKey<String>('manga_ocr_default_engine'),
      title: t.manga_ocr_default_engine,
      subtitle: current == null
          ? null
          : '${current.label}\n${current.description}',
      icon: _engineIcon(selected.preference),
      showIcon: true,
      trailing: FushiIcon(
        FushiIcons.dropDown,
        size: 22,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: locked ? null : () => unawaited(_pickEngine(options, selected)),
    );
  }

  Future<void> _pickEngine(
    List<_EngineOption> options,
    _EngineChoice selected,
  ) async {
    final _EngineChoice? picked = await showMangaPanelOptionSheet<_EngineChoice>(
      context: context,
      title: t.manga_ocr_default_engine,
      options: <MangaPanelOption<_EngineChoice>>[
        for (final _EngineOption option in options)
          MangaPanelOption<_EngineChoice>(
            value: option.choice,
            label: option.label,
            description: option.description,
            icon: _engineIcon(option.preference),
            enabled: option.enabled,
            key: ValueKey<String>(
              'manga_ocr_engine_${option.preference.name}'
              '_${option.localModel?.key ?? ''}_${option.hostModel ?? ''}',
            ),
          ),
      ],
      selected: selected,
    );
    if (!mounted || picked == null || picked == _currentChoice) return;
    await _selectEngine(picked);
  }

  /// 当前引擎偏好是否真的会用到本地 ONNX 模型。
  ///
  /// `auto` 会在离线优先的兜底顺序里挑到本地模型，所以算「用得到」；显式选了
  /// Lens / 外部 mokuro / 配对主机的，本机一个字节都不需要。
  bool get _localModelsUsedByEngine =>
      _enginePreference == MangaOcrEnginePreference.auto ||
      _enginePreference == MangaOcrEnginePreference.localOnnx;

  /// 设置页「本地模型」分组：状态卡（已就绪 / 需下载 + 体积 + 波浪进度 + 下载 /
  /// 导入按钮组，与阅读器侧板同一张卡）。
  ///
  /// 当前引擎用不到本机模型时**收起成一行摘要**（模型名 +「用不到」+ 体积 /
  /// 占用），点开才露出完整的卡——修的是「我选的是 Google Lens，这儿怎么还让我
  /// 下模型」；但不藏（BUG-1780：出厂默认就是 Lens，想预先备好离线模型的人仍要
  /// 找得到下载入口，磁盘上的残留也得删得掉）。下载中、加载中一律展开。
  Widget _buildSettingsModelGroup(ThemeData theme) {
    final bool collapsible =
        widget.service.isSupportedPlatform &&
        !_downloading &&
        !_loadingStatus &&
        !_localModelsUsedByEngine;
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SettingsSectionHeader(t.manga_reader_group_ocr_model),
          if (collapsible) ...<Widget>[
            _buildModelSummary(theme),
            _MotionSize(
              duration: spring.duration,
              curve: spring.curve,
              alignment: Alignment.topCenter,
              child: _modelDetailsExpanded
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildPanelModelArea(theme),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ] else
            _buildPanelModelArea(theme),
        ],
      ),
    );
  }

  /// 收起态摘要：弱化的描边卡，整卡可点（键盘焦点 / 手柄 A 同样可达）展开详情。
  Widget _buildModelSummary(ThemeData theme) {
    final MangaOcrModelStatus? status = _status;
    final String title = widget.localModelGetter == null
        ? t.manga_reader_group_ocr_model
        : localModelLabel(_localModel);
    final String? size = status == null
        ? null
        : status.hasAnyFiles
        ? t.manga_ocr_model_disk_usage(size: _formatBytes(status.diskBytes))
        : _modelSizeSubtitle(status);
    final FushiSpringSpec spring = context.fushiMotion.spatialFast;
    final String toggleLabel = _modelDetailsExpanded
        ? t.manga_ocr_model_details_hide
        : t.manga_ocr_model_details_show;
    return Semantics(
      button: true,
      expanded: _modelDetailsExpanded,
      label: toggleLabel,
      child: FushiCard(
        key: const ValueKey<String>('manga_ocr_model_summary'),
        variant: FushiCardVariant.outlined,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        onTap: () =>
            setState(() => _modelDetailsExpanded = !_modelDetailsExpanded),
        child: Row(
          children: <Widget>[
            FushiListLeadingIcon(
              (status?.hasAnyFiles ?? false)
                  ? FushiIcons.storage
                  : FushiIcons.modelTraining,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      t.manga_ocr_model_unused_by_engine,
                      if (size != null) size,
                    ].join('\n'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedRotation(
              turns: _modelDetailsExpanded ? 0.5 : 0,
              duration: spring.duration,
              curve: spring.curve,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: FushiIcon(
                  FushiIcons.expandMore,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 引擎是「自动」时状态行说的是哪个本机模型并不显然（模型选择已并进引擎
  /// 下拉），副标题前缀模型名把它说清楚。宿主没接模型偏好时不加。
  String? _withModelName(String? subtitle) {
    if (widget.localModelGetter == null) return subtitle;
    final String name = localModelLabel(_localModel);
    return subtitle == null ? name : '$name · $subtitle';
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
    // 有半成品就直接给「已下 / 共」的绝对进度，而不是干巴巴一句「需下载
    // 470 MB」——后者在下过一半的用户眼里等于「刚才那趟没算数」。
    final String? needed = status.totalBytes <= 0
        ? null
        : status.obtainedBytes > 0
        ? t.manga_ocr_download_total_progress(
            done: _formatBytes(status.obtainedBytes),
            total: _formatBytes(status.totalBytes),
          )
        : t.manga_ocr_model_download_size(
            size: _formatBytes(status.totalBytes),
          );
    final String joined = <String?>[
      usage,
      needed,
    ].whereType<String>().join(' · ');
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
    return FushiOutlinedButton.icon(
      onPressed: (_deleting || _downloading || _importing)
          ? null
          : _confirmDelete,
      icon: _deleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            )
          : const FushiIcon(FushiIcons.delete, size: 18),
      label: Text(t.manga_ocr_delete),
    );
  }

  // ── 阅读器设置侧板版式（M3E）─────────────────────────────────────────
  //
  // 与设置页版式读写同一批偏好、走同一组回调，只换呈现：引擎是带图标的单选卡片组
  // （说明随卡片给出，不再藏在下拉里）、选项是分段 / 选择行（长说明收进 info）、
  // 本机模型是一张强调卡（状态 + 体积 + 波浪进度 + 下载 / 导入按钮组）。

  static IconData _engineIcon(MangaOcrEnginePreference preference) =>
      switch (preference) {
        MangaOcrEnginePreference.auto => FushiIcons.brightnessAuto,
        MangaOcrEnginePreference.localOnnx => FushiIcons.modelTraining,
        MangaOcrEnginePreference.systemOcr => FushiIcons.devices,
        MangaOcrEnginePreference.googleLens => FushiIcons.travelExplore,
        MangaOcrEnginePreference.externalMokuro => FushiIcons.system,
        MangaOcrEnginePreference.pairedHost => FushiIcons.hub,
      };

  Widget _panelTitle(String text) => FushiSectionTitle.group(
    text,
    padding: const EdgeInsets.only(top: 4, bottom: 8),
  );

  Widget _buildPanelBody(ThemeData theme) {
    final List<Widget> options = <Widget>[
      if (isDesktopPlatform && widget.parallelTasksGetter != null)
        _buildPanelParallelTasks(),
      if (widget.lensLanguageGetter != null) _buildPanelLensLanguage(),
      if (widget.aiModeGetter != null) _buildPanelAiMode(theme),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _panelTitle(t.manga_reader_group_ocr_engine),
        _buildPanelEngines(),
        const SizedBox(height: 16),
        MangaPanelGroup(
          title: t.manga_reader_group_ocr_options,
          children: options,
        ),
        _panelTitle(t.manga_reader_group_ocr_model),
        _buildPanelModelArea(theme),
        // 外部 mokuro CLI 是桌面工具，仅桌面显示。
        if (isDesktopPlatform) ...<Widget>[
          const SizedBox(height: 16),
          MangaPanelGroup(
            title: t.manga_reader_group_ocr_external,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: _buildPanelExternal(theme),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildPanelEngines() {
    final List<_EngineOption> engines = _engineOptions();
    return KeyedSubtree(
      key: const ValueKey<String>('manga_ocr_default_engine'),
      child: MangaPanelRadioCards<_EngineChoice>(
        options: <MangaPanelOption<_EngineChoice>>[
          for (final _EngineOption option in engines)
            MangaPanelOption<_EngineChoice>(
              value: option.choice,
              label: option.label,
              description: option.description,
              icon: _engineIcon(option.preference),
              enabled: option.enabled,
              key: ValueKey<String>(
                'manga_ocr_engine_${option.preference.name}'
                '_${option.localModel?.key ?? ''}_${option.hostModel ?? ''}',
              ),
            ),
        ],
        selected: _currentChoice,
        // 导入 / 删除期间锁住：两者都按当前模型的目录动文件（同设置页版式）。
        onChanged: _importing || _deleting
            ? null
            : (_EngineChoice value) {
                if (value == _currentChoice) return;
                unawaited(_selectEngine(value));
              },
      ),
    );
  }

  Widget _buildPanelParallelTasks() {
    return MangaPanelChoiceRow<int>(
      key: const ValueKey<String>('manga_ocr_parallel_tasks'),
      title: t.manga_ocr_parallel_tasks,
      icon: FushiIcons.speed,
      info: t.manga_ocr_parallel_tasks_desc,
      options: <MangaPanelOption<int>>[
        MangaPanelOption<int>(value: 0, label: t.manga_ocr_parallel_auto),
        for (int count = 1; count <= 4; count++)
          MangaPanelOption<int>(value: count, label: '$count'),
      ],
      selected: _parallelTasks,
      onChanged: widget.parallelTasksSetter == null
          ? null
          : (int value) async {
              await widget.parallelTasksSetter!(value);
              if (mounted) setState(() => _parallelTasks = value);
            },
    );
  }

  Widget _buildPanelLensLanguage() {
    return MangaPanelChoiceRow<String>(
      key: const ValueKey<String>('manga_ocr_lens_language'),
      title: t.manga_ocr_lens_language_label,
      icon: FushiIcons.language,
      options: <MangaPanelOption<String>>[
        for (final (String tag, String label) in kGoogleLensLanguageOptions)
          MangaPanelOption<String>(value: tag, label: label),
        if (!kGoogleLensLanguageOptions.any(
          ((String, String) option) => option.$1 == _lensLanguage,
        ))
          MangaPanelOption<String>(value: _lensLanguage, label: _lensLanguage),
      ],
      selected: _lensLanguage,
      onChanged: (String value) {
        setState(() => _lensLanguage = value);
        unawaited(_writeLensLanguage(value));
      },
    );
  }

  /// 大模型识别：关 / 低置信度 / 全部 三段；当前档位的完整说法作副标题，取舍
  /// 说明收进 info。开着却没指派提供商时明说「不会发送」并给入口。
  Widget _buildPanelAiMode(ThemeData theme) {
    final bool missingProvider =
        _aiMode != MangaAiOcrMode.off &&
        !(widget.aiProviderReady?.call() ?? false);
    final Future<void> Function(BuildContext context)? openAiSettings =
        widget.openAiSettings;
    final List<Widget> notes = <Widget>[
      if (_aiMode == MangaAiOcrMode.lowConfidence)
        Text(
          t.manga_ocr_ai_mode_low_confidence_legacy,
          key: const ValueKey<String>(
            'manga_ocr_ai_mode_low_confidence_legacy',
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: fushiNeutralSecondaryForeground(context),
          ),
        ),
      if (missingProvider) ...<Widget>[
        Text(
          t.manga_ocr_ai_mode_no_provider,
          key: const ValueKey<String>('manga_ocr_ai_mode_no_provider'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        if (openAiSettings != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiFilledButton.tonalIcon(
              onPressed: () async {
                await openAiSettings(context);
                // build 里现算 missingProvider：回来后重建一次即刷新。
                if (mounted) setState(() {});
              },
              icon: const FushiIcon(FushiIcons.ai, size: 18),
              label: Text(t.manga_ocr_ai_mode_open_settings),
            ),
          ),
      ],
    ];
    return MangaPanelSegmentedRow<MangaAiOcrMode>(
      key: const ValueKey<String>('manga_ocr_ai_mode'),
      title: t.manga_ocr_ai_mode_label,
      subtitle: switch (_aiMode) {
        MangaAiOcrMode.off => null,
        MangaAiOcrMode.lowConfidence => t.manga_ocr_ai_mode_low_confidence,
        MangaAiOcrMode.all => t.manga_ocr_ai_mode_all,
      },
      icon: FushiIcons.ai,
      info: t.manga_ocr_ai_mode_desc,
      options: <MangaPanelOption<MangaAiOcrMode>>[
        MangaPanelOption<MangaAiOcrMode>(
          value: MangaAiOcrMode.off,
          label: t.manga_ocr_ai_mode_off,
        ),
        MangaPanelOption<MangaAiOcrMode>(
          value: MangaAiOcrMode.lowConfidence,
          label: t.manga_ocr_ai_mode_low_confidence_short,
        ),
        MangaPanelOption<MangaAiOcrMode>(
          value: MangaAiOcrMode.all,
          label: t.manga_ocr_ai_mode_all_short,
        ),
      ],
      selected: _aiMode,
      onChanged: widget.aiModeSetter == null
          ? null
          : (MangaAiOcrMode value) async {
              if (value == _aiMode) return;
              setState(() => _aiMode = value);
              await widget.aiModeSetter!(value.storageKey);
            },
      footer: notes.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final (int i, Widget note) in notes.indexed) ...<Widget>[
                  if (i > 0) const SizedBox(height: 6),
                  note,
                ],
              ],
            ),
    );
  }

  /// 本机模型强调卡：引擎用得到 → 状态卡；用不到 → 磁盘干净给次级下载入口、
  /// 有残留给删除（设置页版式在此之上再加一层收起，见 [_buildSettingsModelGroup]），
  /// 只换呈现。
  Widget _buildPanelModelArea(ThemeData theme) {
    if (!widget.service.isSupportedPlatform) {
      return _panelModelCard(
        theme,
        tone: FushiCardTone.neutral,
        icon: FushiIcons.block,
        title: t.manga_ocr_unsupported,
      );
    }
    if (_downloading) return _panelActiveModelCard(theme);
    if (_loadingStatus) {
      return FushiCard(
        padding: const EdgeInsets.all(20),
        child: FushiLinearProgressIndicator(),
      );
    }
    if (_localModelsUsedByEngine) return _panelActiveModelCard(theme);
    final MangaOcrModelStatus? status = _status;
    if (status == null || !status.hasAnyFiles) {
      // 引擎用不到、磁盘也干净：不劝，但也不藏（BUG-1780）。
      return _panelModelCard(
        theme,
        tone: FushiCardTone.neutral,
        icon: FushiIcons.download,
        title: t.manga_ocr_model_unused_by_engine,
        subtitle: _modelSizeSubtitle(_status),
        actions: <Widget>[
          FushiFilledButton.tonalIcon(
            onPressed: _importing ? null : _startDownload,
            icon: const FushiIcon(FushiIcons.download, size: 18),
            label: Text(t.manga_ocr_download),
          ),
          _importButton(),
        ],
      );
    }
    // 引擎用不到、但磁盘上还占着：说清楚 + 删除 + 继续导入。
    return _panelModelCard(
      theme,
      tone: FushiCardTone.neutral,
      icon: FushiIcons.folder,
      title: t.manga_ocr_model_unused_by_engine,
      subtitle: t.manga_ocr_model_disk_usage(
        size: _formatBytes(status.diskBytes),
      ),
      actions: <Widget>[_deleteButton(), _importButton()],
    );
  }

  /// 引擎用得到本机模型（或正在下载）时的强调卡。
  Widget _panelActiveModelCard(ThemeData theme) {
    final MangaOcrModelStatus? status = _status;
    final bool ready = status?.allReady ?? false;
    if (_downloading) {
      final double? value = _downloadProgressValue;
      return _panelModelCard(
        theme,
        tone: FushiCardTone.secondary,
        icon: FushiIcons.downloading,
        title: t.manga_ocr_model_status_missing,
        subtitle: _withModelName(null),
        trailing: value == null
            ? null
            : Text(
                '${(value * 100).round()}%',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  // 与所在强调卡（secondary）同一配对前景，见 [_panelModelCard]。
                  color: fushiCardToneColors(
                    context,
                    FushiCardTone.secondary,
                  )?.onContainer,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
        progress: FushiLinearProgressIndicator(value: value),
        notes: <String>[
          if (_downloadingFile != null)
            t.manga_ocr_downloading_file(file: _downloadingFile!),
          if (_downloadTotalBytes > 0)
            t.manga_ocr_download_total_progress(
              done: _formatBytes(_downloadReceivedBytes),
              total: _formatBytes(_downloadTotalBytes),
            ),
          t.manga_ocr_download_background_hint,
        ],
        actions: <Widget>[
          FushiOutlinedButton.icon(
            onPressed: _cancelDownload,
            icon: const FushiIcon(FushiIcons.close, size: 18),
            label: Text(t.dialog_cancel),
          ),
        ],
      );
    }
    if (ready) {
      return _panelModelCard(
        theme,
        tone: FushiCardTone.neutral,
        icon: FushiIcons.downloadDone,
        title: t.manga_ocr_model_status_ready,
        subtitle: _withModelName(_modelSizeSubtitle(status)),
        actions: <Widget>[_deleteButton()],
      );
    }
    return _panelModelCard(
      theme,
      tone: FushiCardTone.secondary,
      icon: FushiIcons.download,
      title: t.manga_ocr_model_status_missing,
      subtitle: _withModelName(_modelSizeSubtitle(status)),
      actions: <Widget>[
        FushiFilledButton.icon(
          onPressed: _importing ? null : _startDownload,
          icon: const FushiIcon(FushiIcons.download, size: 18),
          // 「继续下载」只是把已有的 Range 续传说出来。
          label: Text(
            (status?.hasResumableDownload ?? false)
                ? t.manga_ocr_download_resume
                : t.manga_ocr_download,
          ),
        ),
        _importButton(),
        // 模型不全但磁盘上有残留时也得能直接清掉。
        if (status?.hasAnyFiles ?? false) _deleteButton(),
      ],
    );
  }

  /// 模型卡骨架：形状底图标 + 标题 / 副标题（+ 尾部大数字）+ 波浪进度 + 说明 +
  /// 按钮组。[tone] 为 secondary 时是饱和强调色块（需要用户动手的状态）。
  Widget _panelModelCard(
    ThemeData theme, {
    required FushiCardTone tone,
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    Widget? progress,
    List<String> notes = const <String>[],
    List<Widget> actions = const <Widget>[],
  }) {
    final bool emphasis = tone != FushiCardTone.neutral;
    // 卡内文字只取排版角色，颜色跟卡片的配对前景走（secondaryContainer →
    // onSecondaryContainer）。textTheme 的样式自带页面 onSurface 色，原样传给
    // Text 会盖掉 FushiCard 写进 DefaultTextStyle 的前景——自定义主题下浅色
    // surface + 深色容器就成了深底黑字（HBK-AUDIT-022）。中性卡 onCard 为 null，
    // copyWith(color: null) 保持原样。
    final Color? onCard = fushiCardToneColors(context, tone)?.onContainer;
    return FushiCard(
      key: const ValueKey<String>('manga_ocr_model_card'),
      tone: tone,
      padding: const EdgeInsets.all(16),
      child: _MotionSize(
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                FushiListLeadingIcon(
                  icon,
                  size: 48,
                  shape: emphasis
                      ? FushiLeadingShape.cookie
                      : FushiLeadingShape.circle,
                  tone: emphasis ? FushiCardTone.primary : FushiCardTone.secondary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: onCard,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: onCard,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: 12),
                  trailing,
                ],
              ],
            ),
            if (progress != null) ...<Widget>[
              const SizedBox(height: 16),
              progress,
            ],
            for (final String note in notes) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(color: onCard),
              ),
            ],
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPanelExternal(ThemeData theme) {
    final String? probeResult = _probeResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiTextField(
          controller: _pathCtrl,
          size: FushiInputSize.large,
          labelText: t.manga_ocr_external_cli_label,
          helperText: t.manga_ocr_external_cli_hint,
          prefixIcon: const FushiIcon(FushiIcons.system, size: 20),
          onChanged: (String v) => unawaited(_writePath(v.trim())),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('manga_ocr_external_detect'),
            onPressed: _probing ? null : _detectExternal,
            icon: _probing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  )
                : const FushiIcon(FushiIcons.search, size: 18),
            label: Text(t.manga_ocr_external_detect),
          ),
        ),
        _MotionSize(
          duration: context.fushiMotion.spatialDefault.duration,
          curve: context.fushiMotion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: probeResult == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FushiInlineNotice(
                    key: const ValueKey<String>('manga_ocr_external_result'),
                    message: probeResult,
                    severity: _probeFound
                        ? FushiNoticeSeverity.success
                        : FushiNoticeSeverity.warning,
                  ),
                ),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) => FushiByteFormat.bytes(bytes);
}

/// 引擎下拉的值：引擎偏好 + （本机 ONNX 时）具体模型。
@immutable
class _EngineChoice {
  const _EngineChoice(this.preference, this.localModel, {this.hostModel});

  final MangaOcrEnginePreference preference;
  final MangaOcrLocalModel? localModel;

  /// 「Fushi 互联服务端」点名的服务端模型 key；null = 服务端默认。
  final String? hostModel;

  @override
  bool operator ==(Object other) =>
      other is _EngineChoice &&
      other.preference == preference &&
      other.localModel == localModel &&
      other.hostModel == hostModel;

  @override
  int get hashCode => Object.hash(preference, localModel, hostModel);
}

/// 引擎下拉的一项：偏好值 + 标签 + 取舍说明 + 本平台是否可用。
class _EngineOption {
  const _EngineOption({
    required this.preference,
    this.localModel,
    this.hostModel,
    required this.label,
    required this.description,
    required this.enabled,
  });

  final MangaOcrEnginePreference preference;

  /// 本机 ONNX 项对应的模型；其余引擎为 null。
  final MangaOcrLocalModel? localModel;

  /// 服务端模型项对应的 key；「服务端默认」与其余引擎为 null。
  final String? hostModel;

  _EngineChoice get choice =>
      _EngineChoice(preference, localModel, hostModel: hostModel);

  final String label;

  /// 一句话取舍：联网/上传/质量/下载量，用户据此挑引擎。
  final String description;

  final bool enabled;
}

/// 动效开时就是 [AnimatedSize]；「减弱动态效果」/ 墨水屏把时长归零时直接给最终
/// 几何。零时长的 [AnimatedSize] 不可用：子尺寸一变，`RenderAnimatedSize` 在
/// 自身 performLayout 里 `forward(from: 0)` 同步跳到终点、监听器随即
/// `markNeedsLayout`，debug 下断言「mutated in its own performLayout」。
class _MotionSize extends StatelessWidget {
  const _MotionSize({
    required this.duration,
    required this.curve,
    required this.alignment,
    required this.child,
  });

  final Duration duration;
  final Curve curve;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) return child;
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: alignment,
      child: child,
    );
  }
}
