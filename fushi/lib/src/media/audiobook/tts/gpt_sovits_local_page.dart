/// 「本机 GPT-SoVITS」页：在 app 里下载官方整合包、装到本机、启动 / 停止服务、
/// 看日志、一键新建指向它的朗读声音——用户不必再自己下 10 GB 的 7z、解压、开命令行
/// 起 `api_v2.py`、手抄地址。
///
/// 状态全在 [GptSovitsLocalEngine]（引擎层）；本页只渲染与转发操作。仅 Windows 有入口
/// （官方只有 Windows 免安装整合包）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_engine.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_package.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart'
    show LocalInstallRemoveException;
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart'
    show localInstallRemoveFailureText;
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开本页。返回在本页新建的声音预设 id（没新建返回 null）。
Future<String?> openGptSovitsLocalPage(
  BuildContext context,
  TtsServices services,
) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    builder: (_) => GptSovitsLocalPage(services: services),
  ),
);

/// 字节数的人类可读形式（GB 保留一位）。
String formatGptSovitsBytes(int bytes) {
  const int mb = 1024 * 1024;
  const int gb = 1024 * mb;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

class GptSovitsLocalPage extends StatefulWidget {
  const GptSovitsLocalPage({required this.services, super.key});

  final TtsServices services;

  @override
  State<GptSovitsLocalPage> createState() => _GptSovitsLocalPageState();
}

class _GptSovitsLocalPageState extends State<GptSovitsLocalPage> {
  GptSovitsLocalEngine get _engine => widget.services.localGptSovits;

  String? _installDir;

  /// null = 还在检测；'' = 没有 N 卡。
  String? _gpu;
  GptSovitsPackageVariant? _variantOverride;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngine);
    unawaited(_init());
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final Directory support = await enginePaths.supportRootDirectory();
    final String? gpu = await detectNvidiaGpuName();
    if (!mounted) return;
    setState(() {
      _installDir ??= GptSovitsLocalEngine.defaultInstallDir(support);
      _gpu = gpu ?? '';
    });
  }

  GptSovitsPackageVariant get _variant =>
      _variantOverride ?? gptSovitsVariantForGpu(_gpu);

  AppModel get _appModel =>
      ProviderScope.containerOf(context, listen: false).read(appProvider);

  Future<void> _pickInstallDir() async {
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel: _appModel,
      initialDirectory: _installDir,
    );
    if (dir == null || !mounted) return;
    setState(() => _installDir = dir);
  }

  Future<void> _pickSource() async {
    final GptSovitsPackageSource? picked =
        await showFushiChoiceDialog<GptSovitsPackageSource>(
          context: context,
          title: t.audiobook_tts_local_source,
          selected: _engine.settings.source,
          options: <FushiChoiceOption<GptSovitsPackageSource>>[
            for (final GptSovitsPackageSource s
                in GptSovitsPackageSource.values)
              FushiChoiceOption<GptSovitsPackageSource>(
                value: s,
                label: _sourceLabel(s),
              ),
          ],
        );
    if (picked == null) return;
    await _engine.setSource(picked);
  }

  Future<void> _pickVariant() async {
    final GptSovitsPackageVariant? picked =
        await showFushiChoiceDialog<GptSovitsPackageVariant>(
          context: context,
          title: t.audiobook_tts_local_variant,
          selected: _variant,
          options: <FushiChoiceOption<GptSovitsPackageVariant>>[
            for (final GptSovitsPackageVariant v
                in GptSovitsPackageVariant.values)
              FushiChoiceOption<GptSovitsPackageVariant>(
                value: v,
                label: _variantLabel(v),
              ),
          ],
        );
    if (picked == null || !mounted) return;
    setState(() => _variantOverride = picked);
  }

  Future<void> _install() async {
    final String? dir = _installDir;
    if (dir == null) return;
    await _engine.install(installDir: dir, variant: _variant);
  }

  Future<void> _useExisting() async {
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel: _appModel,
      dialogTitle: t.audiobook_tts_local_use_existing_hint,
    );
    if (dir == null || !mounted) return;
    if (!await _engine.useExisting(dir)) {
      FushiToast.show(msg: t.audiobook_tts_local_use_existing_invalid);
    }
  }

  Future<void> _remove() async {
    final GptSovitsLocalSettings settings = _engine.settings;
    final bool deleteFiles = _engine.canDeleteFiles;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: deleteFiles
          ? t.audiobook_tts_local_delete
          : t.audiobook_tts_local_remove,
      message: deleteFiles
          ? t.audiobook_tts_local_delete_confirm(path: settings.dir ?? '')
          : t.audiobook_tts_local_remove_hint,
      destructive: deleteFiles,
    );
    if (!confirmed) return;
    try {
      await _engine.remove(deleteFiles: deleteFiles);
    } on LocalInstallRemoveException catch (error) {
      FushiToast.show(
        msg: localInstallRemoveFailureText(error),
        severity: ToastSeverity.error,
      );
    }
  }

  Future<void> _showLog() async {
    final List<String> lines = _engine.server.logTail;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => FushiAlertDialog(
        title: Text(t.audiobook_tts_local_log),
        content: SizedBox(
          width: 560,
          height: 360,
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(
              lines.isEmpty
                  ? t.audiobook_tts_local_log_empty
                  : lines.join('\n'),
              style: Theme.of(
                dialogContext,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: <Widget>[
          FushiDialogAction(
            label: t.dialog_ok,
            kind: FushiDialogActionKind.primary,
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  /// 新建一份指向本机服务的 GPT-SoVITS 声音，返回给调用方去编辑（选参考音频）。
  Future<void> _createVoice() async {
    final TtsPresetStore store = widget.services.store;
    final TtsProviderDescriptor descriptor =
        widget.services.registry[GptSovitsTtsDescriptor.providerId]!;
    final TtsVoicePreset preset = TtsVoicePreset(
      id: newTtsPresetId(),
      providerId: descriptor.id,
      name: t.audiobook_tts_local_voice_name,
      params: <String, String>{
        ...ttsDefaultParams(descriptor),
        GptSovitsTtsDescriptor.endpointKey: _engine.endpoint,
      },
    );
    await store.savePresets(<TtsVoicePreset>[...store.loadPresets(), preset]);
    if (store.activePresetId == null) await store.setActivePresetId(preset.id);
    if (mounted) Navigator.of(context).pop(preset.id);
  }

  static String _sourceLabel(GptSovitsPackageSource s) => switch (s) {
    GptSovitsPackageSource.huggingFace => t.audiobook_tts_local_source_hf,
    GptSovitsPackageSource.modelScope => t.audiobook_tts_local_source_ms,
  };

  static String _variantLabel(GptSovitsPackageVariant v) => switch (v) {
    GptSovitsPackageVariant.standard => t.audiobook_tts_local_variant_standard,
    GptSovitsPackageVariant.nvidia50 => t.audiobook_tts_local_variant_nvidia50,
  };

  String? _installFailureText(GptSovitsInstallFailure? f) => switch (f) {
    null => null,
    GptSovitsInstallFailure.network => t.audiobook_tts_local_failure_network,
    GptSovitsInstallFailure.corrupt => t.audiobook_tts_local_failure_corrupt,
    GptSovitsInstallFailure.noExtractor =>
      t.audiobook_tts_local_failure_no_extractor,
    GptSovitsInstallFailure.extractFailed =>
      t.audiobook_tts_local_failure_extract,
    GptSovitsInstallFailure.layoutMissing =>
      t.audiobook_tts_local_failure_layout,
    GptSovitsInstallFailure.disk => t.audiobook_tts_local_failure_disk,
  };

  String _serverStatus() {
    final GptSovitsLocalServer server = _engine.server;
    return switch (server.phase) {
      GptSovitsServerPhase.stopped => t.audiobook_tts_local_server_stopped,
      GptSovitsServerPhase.starting => t.audiobook_tts_local_server_starting,
      GptSovitsServerPhase.running when server.isExternal =>
        t.audiobook_tts_local_server_external(endpoint: _engine.endpoint),
      GptSovitsServerPhase.running => t.audiobook_tts_local_server_running(
        endpoint: _engine.endpoint,
      ),
      GptSovitsServerPhase.failed => switch (server.failure) {
        GptSovitsServerFailure.notInstalled =>
          t.audiobook_tts_local_server_failed_missing,
        GptSovitsServerFailure.spawnFailed =>
          t.audiobook_tts_local_server_failed_spawn,
        GptSovitsServerFailure.timeout =>
          t.audiobook_tts_local_server_failed_timeout,
        GptSovitsServerFailure.exited ||
        null => t.audiobook_tts_local_server_failed_exited,
      },
    };
  }

  Widget _secondary(String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: fushiNeutralSecondaryForeground(context),
    ),
  );

  List<Widget> _installSections() {
    final GptSovitsInstaller installer = _engine.installer;
    final bool busy = installer.isBusy;
    final String? failure = installer.step == GptSovitsInstallStep.failed
        ? _installFailureText(installer.failure)
        : null;
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FushiInlineNotice(
          key: const ValueKey<String>('gsv-local-intro'),
          severity: FushiNoticeSeverity.info,
          message: t.audiobook_tts_local_intro,
        ),
      ),
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-gpu'),
            icon: FushiIcons.server,
            showIcon: true,
            title: t.audiobook_tts_local_gpu,
            subtitle: switch (_gpu) {
              null => '…',
              '' => t.audiobook_tts_local_gpu_none,
              final String name => name,
            },
            subtitleMaxLines: 2,
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-variant'),
            title: t.audiobook_tts_local_variant,
            onTap: busy ? null : () => unawaited(_pickVariant()),
            trailing: _secondary(_variantLabel(_variant)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-source'),
            title: t.audiobook_tts_local_source,
            onTap: busy ? null : () => unawaited(_pickSource()),
            trailing: _secondary(_sourceLabel(_engine.settings.source)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-dir'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_local_dir,
            subtitle:
                '${_installDir ?? '…'}\n${t.audiobook_tts_local_dir_hint}',
            subtitleMaxLines: 4,
            onTap: busy ? null : () => unawaited(_pickInstallDir()),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        children: <Widget>[
          if (busy) _progress(installer),
          if (busy)
            AdaptiveSettingsRow(
              key: const ValueKey<String>('gsv-local-cancel'),
              icon: FushiIcons.stop,
              showIcon: true,
              title: t.audiobook_tts_local_cancel,
              onTap: installer.cancel,
            )
          else ...<Widget>[
            AdaptiveSettingsRow(
              key: const ValueKey<String>('gsv-local-install'),
              icon: FushiIcons.download,
              showIcon: true,
              title: t.audiobook_tts_local_install,
              subtitle: t.audiobook_tts_local_install_hint,
              subtitleMaxLines: 2,
              onTap: _installDir == null ? null : () => unawaited(_install()),
            ),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('gsv-local-use-existing'),
              icon: FushiIcons.folder,
              showIcon: true,
              title: t.audiobook_tts_local_use_existing,
              subtitle: t.audiobook_tts_local_use_existing_hint,
              subtitleMaxLines: 2,
              onTap: () => unawaited(_useExisting()),
            ),
          ],
        ],
      ),
      if (failure != null)
        FushiInlineNotice(
          key: const ValueKey<String>('gsv-local-install-failure'),
          severity: FushiNoticeSeverity.error,
          message: failure,
        ),
      if (installer.step == GptSovitsInstallStep.cancelled)
        FushiInlineNotice(
          key: const ValueKey<String>('gsv-local-install-cancelled'),
          severity: FushiNoticeSeverity.info,
          message: t.audiobook_tts_local_cancelled,
        ),
    ];
  }

  Widget _progress(GptSovitsInstaller installer) {
    final int? total = installer.totalBytes;
    final (String label, double? value) = switch (installer.step) {
      GptSovitsInstallStep.downloading => (
        '${t.audiobook_tts_local_step_downloading(name: installer.package?.name ?? '')}\n'
            '${formatGptSovitsBytes(installer.receivedBytes)}'
            '${total == null ? '' : ' / ${formatGptSovitsBytes(total)}'}',
        total == null || total == 0 ? null : installer.receivedBytes / total,
      ),
      GptSovitsInstallStep.extracting => (
        t.audiobook_tts_local_step_extracting(n: installer.extractedEntries),
        null,
      ),
      GptSovitsInstallStep.configuring => (
        t.audiobook_tts_local_step_configuring,
        null,
      ),
      _ => (t.audiobook_tts_local_step_listing, null),
    };
    return Padding(
      key: const ValueKey<String>('gsv-local-progress'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 10),
          FushiLinearProgressIndicator(value: value),
        ],
      ),
    );
  }

  List<Widget> _installedSections(GptSovitsInstallLayout layout) {
    final GptSovitsLocalServer server = _engine.server;
    final bool running = server.isRunning;
    final bool starting = server.phase == GptSovitsServerPhase.starting;
    return <Widget>[
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-server'),
            icon: FushiIcons.server,
            showIcon: true,
            title: t.audiobook_tts_local_server,
            subtitle: _serverStatus(),
            subtitleMaxLines: 3,
            trailing: starting
                ? const SizedBox.square(
                    dimension: 18,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  )
                : FushiTextButton.icon(
                    key: const ValueKey<String>('gsv-local-start-stop'),
                    onPressed: running
                        ? (server.isExternal
                              ? null
                              : () => unawaited(_engine.stop()))
                        : () => unawaited(_engine.start()),
                    icon: FushiIcon(
                      running ? FushiIcons.stop : FushiIcons.play,
                    ),
                    label: Text(
                      running
                          ? t.audiobook_tts_local_stop
                          : t.audiobook_tts_local_start,
                    ),
                  ),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-log'),
            title: t.audiobook_tts_local_log,
            onTap: () => unawaited(_showLog()),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-location'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_local_location,
            subtitle: layout.root,
            subtitleMaxLines: 3,
          ),
        ],
      ),
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gsv-local-create-voice'),
            icon: FushiIcons.voice,
            showIcon: true,
            title: t.audiobook_tts_local_create_voice,
            subtitle: t.audiobook_tts_local_create_voice_hint,
            subtitleMaxLines: 2,
            onTap: () => unawaited(_createVoice()),
          ),
        ],
      ),
      Center(
        child: FushiTextButton.icon(
          key: const ValueKey<String>('gsv-local-remove'),
          destructive: true,
          onPressed: () => unawaited(_remove()),
          icon: const FushiIcon(FushiIcons.delete),
          label: Text(
            _engine.canDeleteFiles
                ? t.audiobook_tts_local_delete
                : t.audiobook_tts_local_remove,
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final GptSovitsInstallLayout? layout = _engine.layout;
    final bool installedView = layout != null && !_engine.installer.isBusy;
    final List<Widget> sections = installedView
        ? _installedSections(layout)
        : _installSections();
    return SettingsKitScaffold(
      title: t.audiobook_tts_local_title,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiEntranceScope(
            // 装好 ↔ 安装中两套分组互换时重开进场窗口。
            replayKey: installedView,
            child: ListView(
              controller: controller,
              key: const ValueKey<String>('gsv-local-list'),
              padding: EdgeInsets.fromLTRB(
                inset,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                inset,
                tokens.spacing.page + bottomSafeInsetOf(context),
              ),
              children: <Widget>[
                for (int i = 0; i < sections.length; i++)
                  FushiStaggeredEntrance(
                    key: ValueKey<String>(
                      'gsv-local-entrance-${installedView ? 'installed' : 'install'}-$i',
                    ),
                    index: i,
                    child: sections[i],
                  ),
              ],
            ),
          ),
    );
  }
}
