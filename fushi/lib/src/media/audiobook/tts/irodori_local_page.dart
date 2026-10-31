/// 「本机 Irodori-TTS」页：在 app 里部署官方 Irodori-TTS-Server（uv + 受管 Python +
/// 锁定依赖 + 模型），启动 / 停止服务、看日志、管理服务上的声音（上传参考音频 /
/// 删除），一键新建指向它的朗读声音。
///
/// 状态全在 [IrodoriLocalEngine]（引擎层）；本页只渲染与转发操作。桌面三端有入口。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_package.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/gpt_sovits_local_page.dart'
    show formatGptSovitsBytes;
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
Future<String?> openIrodoriLocalPage(
  BuildContext context,
  TtsServices services,
) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    builder: (_) => IrodoriLocalPage(services: services),
  ),
);

/// 后端的显示名（macOS 的 cpu extra 实际跑在 Metal 上）。
String irodoriBackendLabel(IrodoriTorchBackend backend) => switch (backend) {
  IrodoriTorchBackend.cu128 => t.audiobook_tts_irodori_local_backend_cu128,
  IrodoriTorchBackend.rocm => t.audiobook_tts_irodori_local_backend_rocm,
  IrodoriTorchBackend.cpu when Platform.isMacOS =>
    t.audiobook_tts_irodori_local_backend_apple,
  IrodoriTorchBackend.cpu => t.audiobook_tts_irodori_local_backend_cpu,
};

String irodoriModelLabel(IrodoriModelChoice model) => switch (model) {
  IrodoriModelChoice.small => t.audiobook_tts_irodori_local_model_small,
  IrodoriModelChoice.smallMeanFlow => t.audiobook_tts_irodori_local_model_mf,
};

String irodoriSourceLabel(IrodoriDownloadSource source) => switch (source) {
  IrodoriDownloadSource.huggingFace => t.audiobook_tts_local_source_hf,
  IrodoriDownloadSource.hfMirror =>
    t.audiobook_tts_irodori_local_source_hf_mirror,
};

class IrodoriLocalPage extends StatefulWidget {
  const IrodoriLocalPage({required this.services, super.key});

  final TtsServices services;

  @override
  State<IrodoriLocalPage> createState() => _IrodoriLocalPageState();
}

class _IrodoriLocalPageState extends State<IrodoriLocalPage> {
  IrodoriLocalEngine get _engine => widget.services.localIrodori;

  String? _installDir;

  /// null = 还在检测；'' = 没有 N 卡（macOS 不检测）。
  String? _gpu;

  /// 服务上的声音；null = 还没取 / 服务没在跑。
  List<IrodoriServerVoice>? _voices;
  bool _voicesBusy = false;
  bool _wasRunning = false;

  /// 本页最近上传的声音（新建朗读声音时默认选它）。
  String? _lastUploaded;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngine);
    _wasRunning = _engine.server.isRunning;
    if (_wasRunning) unawaited(_loadVoices());
    unawaited(_init());
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    if (!mounted) return;
    final bool running = _engine.server.isRunning;
    if (running != _wasRunning) {
      _wasRunning = running;
      if (running) {
        unawaited(_loadVoices());
      } else {
        _voices = null;
      }
    }
    setState(() {});
  }

  Future<void> _init() async {
    final Directory support = await enginePaths.supportRootDirectory();
    final String? gpu = Platform.isMacOS ? null : await detectNvidiaGpuName();
    if (!mounted) return;
    setState(() {
      final String? recorded = _engine.settings.dir;
      _installDir ??= recorded != null
          ? p.dirname(recorded)
          : IrodoriLocalEngine.defaultInstallDir(support);
      _gpu = gpu ?? '';
    });
  }

  /// 实际要装的后端：用户选过的 → 已装的 → 按显卡推荐。
  IrodoriTorchBackend get _backend =>
      _engine.settings.backend ??
      _engine.installedBackend ??
      irodoriBackendFor(
        nvidiaGpu: (_gpu?.isEmpty ?? true) ? null : _gpu,
        isMacOS: Platform.isMacOS,
      );

  AppModel get _appModel =>
      ProviderScope.containerOf(context, listen: false).read(appProvider);

  IrodoriServerVoiceApi get _voiceApi => IrodoriServerVoiceApi(
    endpoint: _engine.endpoint,
    // 本机回环服务：与朗读请求同一个出站装配点。
    httpClientFactory: createAppHttpClient,
  );

  Future<void> _loadVoices() async {
    setState(() => _voicesBusy = true);
    List<IrodoriServerVoice>? voices;
    try {
      voices = await _voiceApi.list();
    } on TtsFailure {
      voices = null;
    }
    if (!mounted) return;
    setState(() {
      _voices = voices;
      _voicesBusy = false;
    });
  }

  Future<void> _pickInstallDir() async {
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel: _appModel,
      initialDirectory: _installDir,
    );
    if (dir == null || !mounted) return;
    setState(() => _installDir = dir);
  }

  Future<void> _pickBackend() async {
    final IrodoriTorchBackend? picked =
        await showFushiChoiceDialog<IrodoriTorchBackend>(
          context: context,
          title: t.audiobook_tts_irodori_local_backend,
          selected: _backend,
          options: <FushiChoiceOption<IrodoriTorchBackend>>[
            for (final IrodoriTorchBackend b in irodoriBackendsFor(
              isMacOS: Platform.isMacOS,
              isLinux: Platform.isLinux,
            ))
              FushiChoiceOption<IrodoriTorchBackend>(
                value: b,
                label: irodoriBackendLabel(b),
              ),
          ],
        );
    if (picked == null) return;
    await _engine.setBackend(picked);
  }

  Future<void> _pickModel() async {
    final IrodoriModelChoice? picked =
        await showFushiChoiceDialog<IrodoriModelChoice>(
          context: context,
          title: t.audiobook_tts_irodori_local_model,
          selected: _engine.settings.model,
          options: <FushiChoiceOption<IrodoriModelChoice>>[
            for (final IrodoriModelChoice m in IrodoriModelChoice.values)
              FushiChoiceOption<IrodoriModelChoice>(
                value: m,
                label: irodoriModelLabel(m),
              ),
          ],
        );
    if (picked == null) return;
    await _engine.setModel(picked);
  }

  Future<void> _pickSource() async {
    final IrodoriDownloadSource? picked =
        await showFushiChoiceDialog<IrodoriDownloadSource>(
          context: context,
          title: t.audiobook_tts_local_source,
          selected: _engine.settings.source,
          options: <FushiChoiceOption<IrodoriDownloadSource>>[
            for (final IrodoriDownloadSource s in IrodoriDownloadSource.values)
              FushiChoiceOption<IrodoriDownloadSource>(
                value: s,
                label: irodoriSourceLabel(s),
              ),
          ],
        );
    if (picked == null) return;
    await _engine.setSource(picked);
  }

  Future<void> _pickPort() async {
    final String? raw = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_tts_irodori_local_port,
      initialValue: '${_engine.settings.port}',
      keyboardType: TextInputType.number,
      validator: (String v) {
        final int? port = int.tryParse(v.trim());
        return port != null && irodoriPortAllowed(port)
            ? null
            : t.audiobook_tts_irodori_local_port_invalid;
      },
    );
    final int? port = raw == null ? null : int.tryParse(raw);
    if (port == null) return;
    await _engine.setPort(port);
  }

  Future<void> _install() async {
    final String? dir = _installDir;
    if (dir == null) return;
    await _engine.install(installDir: dir, backend: _backend);
  }

  Future<void> _remove() async {
    final String path = _engine.settings.dir ?? '';
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.audiobook_tts_irodori_local_delete,
      message: t.audiobook_tts_irodori_local_delete_confirm(path: path),
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

  /// 上传一段参考音频成为服务上的声音。
  Future<void> _upload() async {
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: kIrodoriVoiceAudioExtensions,
    );
    if (path == null || !mounted) return;
    final String suggested = p
        .basenameWithoutExtension(path)
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String? id = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_tts_irodori_local_voice_id,
      message: t.audiobook_tts_irodori_local_voice_id_hint,
      initialValue: suggested,
      validator: (String v) => kIrodoriVoiceIdPattern.hasMatch(v.trim())
          ? null
          : t.audiobook_tts_irodori_local_voice_id_hint,
    );
    if (id == null || !mounted) return;
    try {
      final String uploaded = await _voiceApi.upload(
        file: File(path),
        voiceId: id,
      );
      _lastUploaded = uploaded;
      FushiToast.show(
        msg: t.audiobook_tts_irodori_local_upload_done(id: uploaded),
      );
    } on IrodoriVoiceUploadException catch (e) {
      FushiToast.show(
        msg: e.failure == IrodoriVoiceUploadFailure.exists
            ? t.audiobook_tts_irodori_local_upload_exists
            : t.audiobook_tts_irodori_local_upload_failed,
      );
    }
    if (mounted) await _loadVoices();
  }

  Future<void> _deleteVoice(String id) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.audiobook_tts_irodori_local_voices,
      message: t.audiobook_tts_irodori_local_voice_delete_confirm(id: id),
      destructive: true,
    );
    if (!confirmed) return;
    bool deleted;
    try {
      deleted = await _voiceApi.delete(id);
    } on TtsFailure {
      deleted = false;
    }
    if (!deleted) {
      FushiToast.show(msg: t.audiobook_tts_irodori_local_voice_delete_failed);
    }
    if (mounted) await _loadVoices();
  }

  /// 新建一份指向本机服务的 Irodori 声音，返回给调用方去编辑（选声音、试听）。
  Future<void> _createVoice() async {
    final TtsPresetStore store = widget.services.store;
    final TtsProviderDescriptor descriptor =
        widget.services.registry[IrodoriServerTtsDescriptor.providerId]!;
    final TtsVoicePreset preset = TtsVoicePreset(
      id: newTtsPresetId(),
      providerId: descriptor.id,
      name: t.audiobook_tts_irodori_local_voice_name,
      params: <String, String>{
        ...ttsDefaultParams(descriptor),
        IrodoriServerTtsDescriptor.endpointKey: _engine.endpoint,
        if (_lastUploaded != null)
          IrodoriServerTtsDescriptor.voiceKey: _lastUploaded!,
      },
    );
    await store.savePresets(<TtsVoicePreset>[...store.loadPresets(), preset]);
    if (store.activePresetId == null) await store.setActivePresetId(preset.id);
    if (mounted) Navigator.of(context).pop(preset.id);
  }

  String? _installFailureText(IrodoriInstallFailure? f) => switch (f) {
    null => null,
    IrodoriInstallFailure.unsupported =>
      t.audiobook_tts_irodori_local_failure_unsupported,
    IrodoriInstallFailure.network => t.audiobook_tts_local_failure_network,
    IrodoriInstallFailure.corrupt => t.audiobook_tts_local_failure_corrupt,
    IrodoriInstallFailure.disk => t.audiobook_tts_local_failure_disk,
    IrodoriInstallFailure.environment =>
      t.audiobook_tts_irodori_local_failure_environment,
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

  /// 模型 / 端口两行（装前装后都能改）。
  List<Widget> _optionRows({required bool busy}) => <Widget>[
    AdaptiveSettingsRow(
      key: const ValueKey<String>('irodori-local-model'),
      icon: FushiIcons.modelTraining,
      showIcon: true,
      title: t.audiobook_tts_irodori_local_model,
      onTap: busy ? null : () => unawaited(_pickModel()),
      trailing: _secondary(irodoriModelLabel(_engine.settings.model)),
    ),
    AdaptiveSettingsRow(
      key: const ValueKey<String>('irodori-local-port'),
      title: t.audiobook_tts_irodori_local_port,
      onTap: busy ? null : () => unawaited(_pickPort()),
      trailing: _secondary('${_engine.settings.port}'),
    ),
  ];

  List<Widget> _installSections() {
    final IrodoriInstaller installer = _engine.installer;
    final bool busy = installer.isBusy;
    final String? failure = installer.step == IrodoriInstallStep.failed
        ? _installFailureText(installer.failure)
        : null;
    final bool modelMissing = !busy && _engine.environmentReady;
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FushiInlineNotice(
          key: const ValueKey<String>('irodori-local-intro'),
          severity: FushiNoticeSeverity.info,
          message: modelMissing
              ? t.audiobook_tts_irodori_local_model_missing
              : t.audiobook_tts_irodori_local_intro,
        ),
      ),
      AdaptiveSettingsSection(
        children: <Widget>[
          if (!Platform.isMacOS)
            AdaptiveSettingsRow(
              key: const ValueKey<String>('irodori-local-gpu'),
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
            key: const ValueKey<String>('irodori-local-backend'),
            title: t.audiobook_tts_irodori_local_backend,
            onTap: busy || Platform.isMacOS
                ? null
                : () => unawaited(_pickBackend()),
            trailing: _secondary(irodoriBackendLabel(_backend)),
          ),
          ..._optionRows(busy: busy),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-source'),
            title: t.audiobook_tts_local_source,
            onTap: busy ? null : () => unawaited(_pickSource()),
            trailing: _secondary(irodoriSourceLabel(_engine.settings.source)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-dir'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_local_dir,
            subtitle:
                '${_installDir ?? '…'}\n${t.audiobook_tts_irodori_local_dir_hint}',
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
              key: const ValueKey<String>('irodori-local-cancel'),
              icon: FushiIcons.stop,
              showIcon: true,
              title: t.audiobook_tts_local_cancel,
              onTap: installer.cancel,
            )
          else
            AdaptiveSettingsRow(
              key: const ValueKey<String>('irodori-local-install'),
              icon: FushiIcons.download,
              showIcon: true,
              title: t.audiobook_tts_local_install,
              subtitle: t.audiobook_tts_local_install_hint,
              subtitleMaxLines: 2,
              onTap: _installDir == null || _gpu == null
                  ? null
                  : () => unawaited(_install()),
            ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-install-log'),
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
          key: const ValueKey<String>('irodori-local-install-failure'),
          severity: FushiNoticeSeverity.error,
          message: failure,
        ),
      if (installer.step == IrodoriInstallStep.cancelled)
        FushiInlineNotice(
          key: const ValueKey<String>('irodori-local-install-cancelled'),
          severity: FushiNoticeSeverity.info,
          message: t.audiobook_tts_local_cancelled,
        ),
      if (!busy && _engine.settings.dir != null) _removeButton(),
    ];
  }

  Widget _progress(IrodoriInstaller installer) {
    final int? total = installer.totalBytes;
    final String lastLog = installer.logTail.isEmpty
        ? ''
        : '\n${installer.logTail.last}';
    final (String label, double? value) = switch (installer.step) {
      IrodoriInstallStep.downloadingUv ||
      IrodoriInstallStep.downloadingSource ||
      IrodoriInstallStep.downloadingModel => (
        '${t.audiobook_tts_local_step_downloading(name: installer.currentItem ?? '')}\n'
            '${formatGptSovitsBytes(installer.receivedBytes)}'
            '${total == null ? '' : ' / ${formatGptSovitsBytes(total)}'}',
        total == null || total == 0 ? null : installer.receivedBytes / total,
      ),
      IrodoriInstallStep.installingPython => (
        '${t.audiobook_tts_irodori_local_step_python}$lastLog',
        null,
      ),
      _ => ('${t.audiobook_tts_irodori_local_step_packages}$lastLog', null),
    };
    return Padding(
      key: const ValueKey<String>('irodori-local-progress'),
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
      key: const ValueKey<String>('irodori-local-remove'),
      destructive: true,
      onPressed: () => unawaited(_remove()),
      icon: const FushiIcon(FushiIcons.delete),
      label: Text(t.audiobook_tts_irodori_local_delete),
    ),
  );

  Widget _voicesSection() {
    final bool running = _engine.server.isRunning;
    final List<IrodoriServerVoice>? voices = _voices;
    final List<IrodoriServerVoice> uploaded = <IrodoriServerVoice>[
      for (final IrodoriServerVoice v in voices ?? const <IrodoriServerVoice>[])
        if (!v.noReference) v,
    ];
    return AdaptiveSettingsSection(
      title: t.audiobook_tts_irodori_local_voices,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('irodori-local-upload'),
          icon: FushiIcons.upload,
          showIcon: true,
          title: t.audiobook_tts_irodori_local_upload,
          subtitle: running
              ? t.audiobook_tts_irodori_local_upload_hint
              : t.audiobook_tts_irodori_local_voices_need_running,
          subtitleMaxLines: 2,
          onTap: running ? () => unawaited(_upload()) : null,
          trailing: running
              ? FushiIconButton(
                  key: const ValueKey<String>('irodori-local-voices-refresh'),
                  icon: FushiIcons.refresh,
                  tooltip: t.audiobook_tts_irodori_local_voices,
                  busy: _voicesBusy,
                  onTap: () => unawaited(_loadVoices()),
                )
              : null,
        ),
        if (running && voices != null && uploaded.isEmpty)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-voices-empty'),
            title: t.audiobook_tts_irodori_local_voices_empty,
            titleMaxLines: 3,
          ),
        for (final IrodoriServerVoice v in uploaded)
          AdaptiveSettingsRow(
            key: ValueKey<String>('irodori-local-voice-${v.id}'),
            icon: FushiIcons.voice,
            showIcon: true,
            title: v.id,
            trailing: FushiIconButton(
              icon: FushiIcons.delete,
              tooltip: t.audiobook_tts_irodori_local_voice_delete_confirm(
                id: v.id,
              ),
              onTap: () => unawaited(_deleteVoice(v.id)),
            ),
          ),
      ],
    );
  }

  List<Widget> _installedSections(IrodoriInstallLayout layout) {
    final LocalServiceProcess server = _engine.server;
    final bool running = server.isRunning;
    final bool starting = server.phase == LocalServicePhase.starting;
    return <Widget>[
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-server'),
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
                    key: const ValueKey<String>('irodori-local-start-stop'),
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
            key: const ValueKey<String>('irodori-local-log'),
            title: t.audiobook_tts_local_log,
            onTap: () =>
                unawaited(_showLog(t.audiobook_tts_local_log, server.logTail)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-backend-installed'),
            title: t.audiobook_tts_irodori_local_backend,
            trailing: _secondary(irodoriBackendLabel(_backend)),
          ),
          ..._optionRows(busy: starting),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-location'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_local_dir,
            subtitle: layout.root,
            subtitleMaxLines: 3,
          ),
        ],
      ),
      _voicesSection(),
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('irodori-local-create-voice'),
            icon: FushiIcons.voice,
            showIcon: true,
            title: t.audiobook_tts_local_create_voice,
            subtitle: t.audiobook_tts_irodori_local_create_voice_hint,
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
    final IrodoriInstallLayout? layout = _engine.layout;
    final bool installedView = layout != null && !_engine.installer.isBusy;
    final List<Widget> sections = installedView
        ? _installedSections(layout)
        : _installSections();
    return SettingsKitScaffold(
      title: t.audiobook_tts_irodori_local_title,
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
              key: const ValueKey<String>('irodori-local-list'),
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
                      'irodori-local-entrance-${installedView ? 'installed' : 'install'}-$i',
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
