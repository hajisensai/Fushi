/// 「本机 VOICEVOX / AivisSpeech」页：从官方 GitHub Releases 部署引擎，启动 / 停止、
/// 看日志，一键新建指向它的朗读声音。
///
/// 状态全在 [VoicevoxLocalEngine]（引擎层）；本页只渲染与转发操作。同一个页面服务
/// 两家引擎（按 [VoicevoxLocalEngine.manifest] 区分文案）。桌面三端有入口。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart'
    show LocalInstallRemoveException;
import 'package:fushi_engine/tts/local/voicevox_local_engine.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/gpt_sovits_local_page.dart'
    show formatGptSovitsBytes;
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
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
Future<String?> openVoicevoxLocalPage(
  BuildContext context,
  TtsServices services,
  VoicevoxLocalEngine engine,
) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    builder: (_) => VoicevoxLocalPage(services: services, engine: engine),
  ),
);

/// 本机引擎对应的朗读引擎 id。
String voicevoxLocalProviderId(VoicevoxLocalEngine engine) =>
    switch (engine.manifest.kind) {
      VoicevoxLocalKind.voicevox => VoicevoxTtsDescriptor.providerId,
      VoicevoxLocalKind.aivisSpeech => AivisSpeechTtsDescriptor.providerId,
    };

/// 引擎显示名（VOICEVOX / AivisSpeech）。
String voicevoxLocalEngineName(VoicevoxLocalEngine engine) =>
    ttsProviderLabel(voicevoxLocalProviderId(engine));

String voicevoxAccelLabel(VoicevoxAccel accel) => switch (accel) {
  VoicevoxAccel.cpu => t.audiobook_tts_voicevox_local_accel_cpu,
  VoicevoxAccel.directml => t.audiobook_tts_voicevox_local_accel_directml,
  VoicevoxAccel.nvidia => t.audiobook_tts_voicevox_local_accel_nvidia,
};

/// 「添加声音」菜单里的副标题（含下载体积）。
String voicevoxLocalAddHint(VoicevoxLocalEngine engine) =>
    t.audiobook_tts_voicevox_local_add_hint(
      size: formatGptSovitsBytes(engine.selectedPackage?.totalBytes ?? 0),
    );

class VoicevoxLocalPage extends StatefulWidget {
  const VoicevoxLocalPage({
    required this.services,
    required this.engine,
    super.key,
  });

  final TtsServices services;
  final VoicevoxLocalEngine engine;

  @override
  State<VoicevoxLocalPage> createState() => _VoicevoxLocalPageState();
}

class _VoicevoxLocalPageState extends State<VoicevoxLocalPage> {
  VoicevoxLocalEngine get _engine => widget.engine;
  String get _name => voicevoxLocalEngineName(_engine);
  String get _keyPrefix => 'voicevox-local-${_engine.manifest.installSubdir}';

  String? _installDir;

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
    if (!mounted) return;
    setState(() {
      final String? recorded = _engine.settings.dir;
      _installDir ??= recorded != null
          ? p.dirname(recorded)
          : _engine.defaultInstallDir(support);
    });
  }

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

  Future<void> _pickAccel() async {
    final VoicevoxAccel? picked = await showFushiChoiceDialog<VoicevoxAccel>(
      context: context,
      title: t.audiobook_tts_voicevox_local_accel,
      selected: _engine.selectedPackage?.accel,
      options: <FushiChoiceOption<VoicevoxAccel>>[
        for (final VoicevoxPackage pkg in _engine.packages)
          FushiChoiceOption<VoicevoxAccel>(
            value: pkg.accel,
            label: voicevoxAccelLabel(pkg.accel),
            subtitle: formatGptSovitsBytes(pkg.totalBytes),
          ),
      ],
    );
    if (picked == null) return;
    await _engine.setAccel(picked);
  }

  Future<void> _pickPort() async {
    final String? raw = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_tts_irodori_local_port,
      initialValue: '${_engine.settings.port}',
      keyboardType: TextInputType.number,
      validator: (String v) {
        final int? port = int.tryParse(v.trim());
        return port != null && voicevoxPortAllowed(port)
            ? null
            : t.audiobook_tts_voicevox_local_port_invalid;
      },
    );
    final int? port = raw == null ? null : int.tryParse(raw);
    if (port == null) return;
    await _engine.setPort(port);
  }

  Future<void> _install() async {
    final String? dir = _installDir;
    if (dir == null) return;
    await _engine.install(installDir: dir);
  }

  Future<void> _remove() async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.audiobook_tts_voicevox_local_delete(engine: _name),
      message: t.audiobook_tts_voicevox_local_delete_confirm(
        path: _engine.settings.dir ?? '',
      ),
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await _engine.remove(deleteFiles: _engine.canDeleteFiles);
    } on LocalInstallRemoveException catch (error) {
      FushiToast.show(
        msg: localInstallRemoveFailureText(error),
        severity: ToastSeverity.error,
      );
    }
  }

  Future<void> _showLog(String title, List<String> lines) async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => FushiAlertDialog(
        title: Text(title),
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

  /// 新建一份指向本机引擎的声音，返回给调用方去编辑（选角色、试听）。
  Future<void> _createVoice() async {
    final TtsPresetStore store = widget.services.store;
    final TtsProviderDescriptor descriptor =
        widget.services.registry[voicevoxLocalProviderId(_engine)]!;
    final TtsVoicePreset preset = TtsVoicePreset(
      id: newTtsPresetId(),
      providerId: descriptor.id,
      name: t.audiobook_tts_voicevox_local_voice_name(engine: _name),
      params: <String, String>{
        ...ttsDefaultParams(descriptor),
        VoicevoxCompatibleTtsDescriptor.endpointKey: _engine.endpoint,
      },
    );
    await store.savePresets(<TtsVoicePreset>[...store.loadPresets(), preset]);
    if (store.activePresetId == null) await store.setActivePresetId(preset.id);
    if (mounted) Navigator.of(context).pop(preset.id);
  }

  String? _installFailureText(VoicevoxInstallFailure? f) => switch (f) {
    null => null,
    VoicevoxInstallFailure.unsupported =>
      t.audiobook_tts_voicevox_local_failure_unsupported,
    VoicevoxInstallFailure.noExtractor =>
      t.audiobook_tts_voicevox_local_failure_no_extractor,
    VoicevoxInstallFailure.network => t.audiobook_tts_local_failure_network,
    VoicevoxInstallFailure.corrupt => t.audiobook_tts_local_failure_corrupt,
    VoicevoxInstallFailure.disk => t.audiobook_tts_local_failure_disk,
    VoicevoxInstallFailure.extractFailed =>
      t.audiobook_tts_local_failure_extract,
    VoicevoxInstallFailure.layoutMissing =>
      t.audiobook_tts_voicevox_local_failure_layout,
  };

  String _serverStatus() {
    final LocalServiceProcess server = _engine.server;
    return switch (server.phase) {
      LocalServicePhase.stopped => t.audiobook_tts_local_server_stopped,
      LocalServicePhase.starting => t.audiobook_tts_local_server_starting,
      LocalServicePhase.running when server.isExternal =>
        t.audiobook_tts_local_server_external(endpoint: _engine.endpoint),
      LocalServicePhase.running => t.audiobook_tts_local_server_running(
        endpoint: _engine.endpoint,
      ),
      LocalServicePhase.failed => switch (server.failure) {
        LocalServiceFailure.notInstalled =>
          t.audiobook_tts_local_server_failed_missing,
        LocalServiceFailure.spawnFailed =>
          t.audiobook_tts_local_server_failed_spawn,
        LocalServiceFailure.timeout =>
          t.audiobook_tts_local_server_failed_timeout,
        LocalServiceFailure.exited ||
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

  /// 角色使用条款：VOICEVOX 要求公开时标注「VOICEVOX:角色名」。
  Widget _termsNotice() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: FushiInlineNotice(
      key: ValueKey<String>('$_keyPrefix-terms'),
      severity: FushiNoticeSeverity.warning,
      message: _engine.manifest.kind == VoicevoxLocalKind.voicevox
          ? t.audiobook_tts_voicevox_local_terms_voicevox
          : t.audiobook_tts_voicevox_local_terms_aivis,
    ),
  );

  Widget _accelRow({required bool enabled}) => AdaptiveSettingsRow(
    key: ValueKey<String>('$_keyPrefix-accel'),
    icon: FushiIcons.server,
    showIcon: true,
    title: t.audiobook_tts_voicevox_local_accel,
    onTap: enabled && _engine.packages.length > 1
        ? () => unawaited(_pickAccel())
        : null,
    trailing: _secondary(
      voicevoxAccelLabel(_engine.selectedPackage?.accel ?? VoicevoxAccel.cpu),
    ),
  );

  Widget _portRow({required bool enabled}) => AdaptiveSettingsRow(
    key: ValueKey<String>('$_keyPrefix-port'),
    title: t.audiobook_tts_irodori_local_port,
    onTap: enabled ? () => unawaited(_pickPort()) : null,
    trailing: _secondary('${_engine.settings.port}'),
  );

  List<Widget> _installSections() {
    final VoicevoxInstaller installer = _engine.installer;
    final bool busy = installer.isBusy;
    final VoicevoxPackage? pkg = _engine.selectedPackage;
    final String? failure = installer.step == VoicevoxInstallStep.failed
        ? _installFailureText(installer.failure)
        : null;
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FushiInlineNotice(
          key: ValueKey<String>('$_keyPrefix-intro'),
          severity: FushiNoticeSeverity.info,
          message: pkg == null
              ? t.audiobook_tts_voicevox_local_failure_unsupported
              : t.audiobook_tts_voicevox_local_intro(
                  engine: _name,
                  version: _engine.manifest.tag,
                  size: formatGptSovitsBytes(pkg.totalBytes),
                ),
        ),
      ),
      _termsNotice(),
      AdaptiveSettingsSection(
        children: <Widget>[
          _accelRow(enabled: !busy),
          _portRow(enabled: !busy),
          AdaptiveSettingsRow(
            key: ValueKey<String>('$_keyPrefix-dir'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_local_dir,
            subtitle: _installDir ?? '…',
            subtitleMaxLines: 4,
            // 已有（部分）安装时位置固定：换位置先删掉旧的。
            onTap: busy || _engine.settings.dir != null
                ? null
                : () => unawaited(_pickInstallDir()),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        children: <Widget>[
          if (busy) _progress(installer),
          if (busy)
            AdaptiveSettingsRow(
              key: ValueKey<String>('$_keyPrefix-cancel'),
              icon: FushiIcons.stop,
              showIcon: true,
              title: t.audiobook_tts_local_cancel,
              onTap: installer.cancel,
            )
          else
            AdaptiveSettingsRow(
              key: ValueKey<String>('$_keyPrefix-install'),
              icon: FushiIcons.download,
              showIcon: true,
              title: t.audiobook_tts_local_install,
              subtitle: t.audiobook_tts_local_install_hint,
              subtitleMaxLines: 2,
              onTap: _installDir == null || pkg == null
                  ? null
                  : () => unawaited(_install()),
            ),
          AdaptiveSettingsRow(
            key: ValueKey<String>('$_keyPrefix-install-log'),
            title: t.audiobook_tts_irodori_local_install_log,
            onTap: () => unawaited(
              _showLog(
                t.audiobook_tts_irodori_local_install_log,
                installer.logTail,
              ),
            ),
          ),
        ],
      ),
      if (failure != null)
        FushiInlineNotice(
          key: ValueKey<String>('$_keyPrefix-install-failure'),
          severity: FushiNoticeSeverity.error,
          message: failure,
        ),
      if (installer.step == VoicevoxInstallStep.cancelled)
        FushiInlineNotice(
          key: ValueKey<String>('$_keyPrefix-install-cancelled'),
          severity: FushiNoticeSeverity.info,
          message: t.audiobook_tts_local_cancelled,
        ),
      if (!busy && _engine.settings.dir != null) _removeButton(),
    ];
  }

  Widget _progress(VoicevoxInstaller installer) {
    final int? total = installer.totalBytes;
    final (String label, double? value) = switch (installer.step) {
      VoicevoxInstallStep.downloading => (
        '${t.audiobook_tts_local_step_downloading(name: installer.currentItem ?? '')}\n'
            '${formatGptSovitsBytes(installer.receivedBytes)}'
            '${total == null ? '' : ' / ${formatGptSovitsBytes(total)}'}',
        total == null || total == 0 ? null : installer.receivedBytes / total,
      ),
      VoicevoxInstallStep.joining => (
        t.audiobook_tts_voicevox_local_step_joining,
        null,
      ),
      _ => (t.audiobook_tts_voicevox_local_step_extracting, null),
    };
    return Padding(
      key: ValueKey<String>('$_keyPrefix-progress'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          FushiLinearProgressIndicator(value: value),
        ],
      ),
    );
  }

  Widget _removeButton() => Center(
    child: FushiTextButton.icon(
      key: ValueKey<String>('$_keyPrefix-remove'),
      destructive: true,
      onPressed: () => unawaited(_remove()),
      icon: const FushiIcon(FushiIcons.delete),
      label: Text(t.audiobook_tts_voicevox_local_delete(engine: _name)),
    ),
  );

  List<Widget> _installedSections(VoicevoxInstallLayout layout) {
    final LocalServiceProcess server = _engine.server;
    final bool running = server.isRunning;
    final bool starting = server.phase == LocalServicePhase.starting;
    return <Widget>[
      _termsNotice(),
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: ValueKey<String>('$_keyPrefix-server'),
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
                    key: ValueKey<String>('$_keyPrefix-start-stop'),
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
            key: ValueKey<String>('$_keyPrefix-log'),
            title: t.audiobook_tts_local_log,
            onTap: () =>
                unawaited(_showLog(t.audiobook_tts_local_log, server.logTail)),
          ),
          // 换加速要重新下载：已装时只显示，删掉重装再换。
          _accelRow(enabled: false),
          _portRow(enabled: !starting),
          AdaptiveSettingsRow(
            key: ValueKey<String>('$_keyPrefix-location'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_local_dir,
            subtitle: '${layout.engineDir}\n${layout.version}',
            subtitleMaxLines: 4,
          ),
        ],
      ),
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: ValueKey<String>('$_keyPrefix-create-voice'),
            icon: FushiIcons.voice,
            showIcon: true,
            title: t.audiobook_tts_local_create_voice,
            subtitle: t.audiobook_tts_voicevox_local_create_voice_hint,
            subtitleMaxLines: 2,
            onTap: () => unawaited(_createVoice()),
          ),
        ],
      ),
      _removeButton(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final VoicevoxInstallLayout? layout = _engine.layout;
    final bool installedView = layout != null && !_engine.installer.isBusy;
    final List<Widget> sections = installedView
        ? _installedSections(layout)
        : _installSections();
    return SettingsKitScaffold(
      title: t.audiobook_tts_voicevox_local_title(engine: _name),
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
              key: ValueKey<String>('$_keyPrefix-list'),
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
                      '$_keyPrefix-entrance-${installedView ? 'installed' : 'install'}-$i',
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
