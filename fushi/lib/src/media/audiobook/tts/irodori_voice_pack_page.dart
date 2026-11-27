/// 「声音包」页：管理离线制作用的角色声音（Irodori v4-Large 上的 LoRA adapter + 按用途
/// 命名的参考音频组 + 采样参数 + 角色名），并显示批处理 worker 的状态。
///
/// 声音包只记本机路径（清单见 `irodori_voice_packs.dart`），app 不复制、不分发声音。
/// 每个声音包的每组参考音频在制作台的声音 / 选角下拉里是一个可选声音
/// （`pack:<packId>/<group>`）。编辑即保存。桌面端入口在「本机 Irodori-TTS」页。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart'
    show kIrodoriVoiceAudioExtensions;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/state_resource_scope.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/tts_local_log_dialog.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开声音包页。
Future<void> openIrodoriVoicePackPage(
  BuildContext context,
  TtsServices services,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => IrodoriVoicePackPage(services: services),
  ),
);

/// worker 状态一行字（纯函数，测试直接调）。
String irodoriBatchWorkerStatus(IrodoriBatchWorker worker) {
  if (worker.isBusy) {
    return t.audiobook_tts_voice_pack_worker_busy(
      done: worker.done,
      total: worker.total,
    );
  }
  return switch (worker.phase) {
    IrodoriBatchPhase.stopped => t.audiobook_tts_voice_pack_worker_stopped,
    IrodoriBatchPhase.starting => t.audiobook_tts_voice_pack_worker_loading,
    IrodoriBatchPhase.ready => t.audiobook_tts_voice_pack_worker_ready(
      device: worker.device ?? '',
    ),
    IrodoriBatchPhase.failed => t.audiobook_tts_voice_pack_worker_failed,
  };
}

/// 声音包列表里一行的副标题（纯函数）：LoRA / 底模 · 组数，结构不完整或缺文件时
/// 换成问题说明。
String irodoriVoicePackSummary(IrodoriVoicePack pack, List<String> missing) {
  if (pack.validate().isNotEmpty) return t.audiobook_tts_voice_pack_incomplete;
  if (missing.isNotEmpty) {
    return t.audiobook_tts_voice_pack_missing_files(count: missing.length);
  }
  return pack.usesLora
      ? t.audiobook_tts_voice_pack_summary_lora(count: pack.groups.length)
      : t.audiobook_tts_voice_pack_summary_base(count: pack.groups.length);
}

Future<void> _showLines(
  BuildContext context,
  String title,
  List<String> lines,
) => showTtsLocalLogDialog(context, title: title, lines: lines);

/// 列表页与编辑页共用的骨架：设置风格滚动列表，分组错峰进场。
Widget _packScaffold({
  required BuildContext context,
  required String title,
  required String entranceKey,
  required List<Widget> sections,
  Object? replayKey,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final double inset = isGlassDesign(context)
      ? GlassSettingsRenderer.detailHorizontalInset(context)
      : tokens.spacing.page;
  return SettingsKitScaffold(
    title: title,
    leadingIcon: FushiIcons.voice,
    leadingTone: SettingsIconTone.purple,
    bodyConsumesTopPadding: true,
    bodyBuilder:
        (
          BuildContext context,
          ScrollController controller,
          SettingsSectionSpy spy,
        ) => FushiEntranceScope(
          replayKey: replayKey,
          child: ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              inset,
              tokens.spacing.gap + MediaQuery.paddingOf(context).top,
              inset,
              tokens.spacing.page + bottomSafeInsetOf(context),
            ),
            children: <Widget>[
              for (int i = 0; i < sections.length; i++)
                FushiStaggeredEntrance(
                  key: ValueKey<String>('$entranceKey-$i'),
                  index: i,
                  child: sections[i],
                ),
            ],
          ),
        ),
  );
}

class IrodoriVoicePackPage extends ConsumerStatefulWidget {
  const IrodoriVoicePackPage({required this.services, this.store, super.key});

  final TtsServices services;

  /// 测试注入；null = 本机清单（[irodoriVoicePackStoreFor]）。
  final IrodoriVoicePackStore? store;

  @override
  ConsumerState<IrodoriVoicePackPage> createState() =>
      _IrodoriVoicePackPageState();
}

class _IrodoriVoicePackPageState extends ConsumerState<IrodoriVoicePackPage>
    with StateResourceScope<IrodoriVoicePackPage> {
  IrodoriLocalEngine get _engine => widget.services.localIrodori;
  late final IrodoriVoicePackStore _store =
      widget.store ?? irodoriVoicePackStoreFor(ref.read(appProvider));
  late List<IrodoriVoicePack> _packs = _store.load();

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngine);
    onTeardown(() => _engine.removeListener(_onEngine));
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  void _reload() => setState(() => _packs = _store.load());

  Future<void> _add() async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_tts_voice_pack_character,
      icon: FushiIcons.person,
    );
    if (name == null || name.isEmpty || !mounted) return;
    final IrodoriVoicePack pack = _store.upsert(
      IrodoriVoicePack(
        id: IrodoriVoicePackStore.newId(),
        character: name,
        groups: const <IrodoriRefGroup>[],
      ),
    );
    _reload();
    await _edit(pack.id);
  }

  Future<void> _edit(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _IrodoriVoicePackEditor(store: _store, packId: id),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _delete(IrodoriVoicePack pack) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.audiobook_tts_voice_pack_delete_confirm(name: pack.character),
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    _store.remove(pack.id);
    _reload();
  }

  Widget _workerSection() {
    final IrodoriBatchWorker worker = _engine.batchWorker;
    final bool ready = _engine.batchModelReady;
    final bool starting = worker.phase == IrodoriBatchPhase.starting;
    final bool running =
        worker.phase == IrodoriBatchPhase.ready || worker.isBusy;
    return AdaptiveSettingsSection(
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('voice-pack-worker'),
          icon: FushiIcons.server,
          showIcon: true,
          title: t.audiobook_tts_voice_pack_worker,
          subtitle: ready
              ? irodoriBatchWorkerStatus(worker)
              : t.audiobook_tts_voice_pack_needs_large,
          subtitleMaxLines: 3,
          trailing: !ready
              ? null
              : starting
              ? const SizedBox.square(
                  dimension: 18,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                )
              : FushiTextButton.icon(
                  key: const ValueKey<String>('voice-pack-worker-start-stop'),
                  onPressed: worker.isBusy
                      ? null
                      : () =>
                            unawaited(running ? worker.stop() : worker.start()),
                  icon: FushiIcon(running ? FushiIcons.stop : FushiIcons.play),
                  label: Text(
                    running
                        ? t.audiobook_tts_local_stop
                        : t.audiobook_tts_local_start,
                  ),
                ),
        ),
        AdaptiveSettingsRow(
          key: const ValueKey<String>('voice-pack-worker-log'),
          title: t.audiobook_tts_local_log,
          onTap: () => unawaited(
            _showLines(context, t.audiobook_tts_local_log, worker.logTail),
          ),
        ),
      ],
    );
  }

  Widget _packsSection() => AdaptiveSettingsSection(
    title: t.audiobook_tts_voice_pack_title,
    children: <Widget>[
      if (_packs.isEmpty)
        AdaptiveSettingsRow(
          key: const ValueKey<String>('voice-pack-empty'),
          title: t.audiobook_tts_voice_pack_empty,
          titleMaxLines: 4,
        ),
      for (final IrodoriVoicePack pack in _packs)
        AdaptiveSettingsRow(
          key: ValueKey<String>('voice-pack-${pack.id}'),
          icon: FushiIcons.person,
          showIcon: true,
          title: pack.character,
          subtitle: irodoriVoicePackSummary(pack, pack.missingFiles()),
          subtitleMaxLines: 2,
          onTap: () => unawaited(_edit(pack.id)),
          trailing: FushiIconButton(
            icon: FushiIcons.delete,
            tooltip: t.audiobook_tts_voice_pack_delete_confirm(
              name: pack.character,
            ),
            onTap: () => unawaited(_delete(pack)),
          ),
        ),
      AdaptiveSettingsRow(
        key: const ValueKey<String>('voice-pack-add'),
        icon: FushiIcons.add,
        showIcon: true,
        title: t.audiobook_tts_voice_pack_add,
        onTap: () => unawaited(_add()),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => _packScaffold(
    context: context,
    title: t.audiobook_tts_voice_pack_title,
    entranceKey: 'voice-pack-entrance',
    sections: <Widget>[_workerSection(), _packsSection()],
  );
}

/// 编辑一个声音包（编辑即保存）。
class _IrodoriVoicePackEditor extends ConsumerStatefulWidget {
  const _IrodoriVoicePackEditor({required this.store, required this.packId});

  final IrodoriVoicePackStore store;
  final String packId;

  @override
  ConsumerState<_IrodoriVoicePackEditor> createState() =>
      _IrodoriVoicePackEditorState();
}

enum _GroupAction { rename, addFiles, clearFiles, delete }

class _IrodoriVoicePackEditorState
    extends ConsumerState<_IrodoriVoicePackEditor> {
  late IrodoriVoicePack? _pack = widget.store.byId(widget.packId);

  void _save(IrodoriVoicePack next) {
    setState(() => _pack = widget.store.upsert(next));
  }

  Widget _secondary(String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: fushiNeutralSecondaryForeground(context),
    ),
  );

  Future<void> _rename(IrodoriVoicePack pack) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_tts_voice_pack_character,
      initialValue: pack.character,
      icon: FushiIcons.person,
    );
    if (name == null || name.isEmpty || !mounted) return;
    _save(pack.copyWith(character: name));
  }

  Future<void> _pickAdapter(IrodoriVoicePack pack) async {
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel: ref.read(appProvider),
      dialogTitle: t.audiobook_tts_voice_pack_adapter,
    );
    if (dir == null || !mounted) return;
    _save(pack.copyWith(adapterDir: dir));
  }

  Future<String?> _askGroupName(IrodoriVoicePack pack, {String initial = ''}) =>
      showFushiTextInputDialog(
        context: context,
        title: t.audiobook_tts_voice_pack_group_name,
        message: t.audiobook_tts_voice_pack_group_name_hint,
        initialValue: initial,
        validator: (String v) {
          final String name = v.trim();
          if (name.isEmpty) return t.audiobook_tts_voice_pack_group_name;
          final bool taken = pack.groups.any(
            (IrodoriRefGroup g) => g.name == name && g.name != initial,
          );
          return taken ? t.audiobook_tts_voice_pack_group_exists : null;
        },
      );

  Future<void> _addGroup(IrodoriVoicePack pack) async {
    final String? name = await _askGroupName(pack);
    if (name == null || !mounted) return;
    final List<String> files = await pickSystemFilePaths(
      context: context,
      allowedExtensions: kIrodoriVoiceAudioExtensions,
    );
    if (!mounted) return;
    _save(
      pack.copyWith(
        groups: <IrodoriRefGroup>[
          ...pack.groups,
          IrodoriRefGroup(name: name, files: files),
        ],
      ),
    );
  }

  void _replaceGroup(IrodoriVoicePack pack, int index, IrodoriRefGroup? next) {
    final List<IrodoriRefGroup> groups = pack.groups.toList();
    if (next == null) {
      groups.removeAt(index);
    } else {
      groups[index] = next;
    }
    _save(pack.copyWith(groups: groups));
  }

  Future<void> _groupActions(IrodoriVoicePack pack, int index) async {
    final IrodoriRefGroup group = pack.groups[index];
    final _GroupAction? action = await showFushiChoiceDialog<_GroupAction>(
      context: context,
      title: group.name,
      message: group.files.map(p.basename).join('\n'),
      options: <FushiChoiceOption<_GroupAction>>[
        FushiChoiceOption<_GroupAction>(
          value: _GroupAction.addFiles,
          label: t.audiobook_tts_voice_pack_group_add_files,
          icon: FushiIcons.add,
        ),
        FushiChoiceOption<_GroupAction>(
          value: _GroupAction.rename,
          label: t.audiobook_tts_voice_pack_group_rename,
          icon: FushiIcons.edit,
        ),
        FushiChoiceOption<_GroupAction>(
          value: _GroupAction.clearFiles,
          label: t.audiobook_tts_voice_pack_group_clear_files,
          enabled: group.files.isNotEmpty,
        ),
        FushiChoiceOption<_GroupAction>(
          value: _GroupAction.delete,
          label: t.audiobook_tts_voice_pack_group_delete,
          icon: FushiIcons.delete,
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _GroupAction.addFiles:
        final List<String> files = await pickSystemFilePaths(
          context: context,
          allowedExtensions: kIrodoriVoiceAudioExtensions,
        );
        if (files.isEmpty || !mounted) return;
        _replaceGroup(
          pack,
          index,
          IrodoriRefGroup(
            name: group.name,
            files: <String>{...group.files, ...files}.toList(),
          ),
        );
      case _GroupAction.rename:
        final String? name = await _askGroupName(pack, initial: group.name);
        if (name == null || !mounted) return;
        _replaceGroup(
          pack,
          index,
          IrodoriRefGroup(name: name, files: group.files),
        );
      case _GroupAction.clearFiles:
        _replaceGroup(
          pack,
          index,
          IrodoriRefGroup(name: group.name, files: const <String>[]),
        );
      case _GroupAction.delete:
        _replaceGroup(pack, index, null);
    }
  }

  Future<void> _editNumber({
    required String title,
    required String initial,
    required bool integer,
    required void Function(num value) apply,
  }) async {
    num? parse(String v) =>
        integer ? int.tryParse(v.trim()) : double.tryParse(v.trim());
    final String? raw = await showFushiTextInputDialog(
      context: context,
      title: title,
      initialValue: initial,
      keyboardType: TextInputType.numberWithOptions(decimal: !integer),
      validator: (String v) {
        final num? n = parse(v);
        return n == null || n < 0
            ? t.audiobook_tts_voice_pack_invalid_number
            : null;
      },
    );
    if (raw == null || !mounted) return;
    final num? value = parse(raw);
    if (value != null) apply(value);
  }

  List<Widget> _sections(IrodoriVoicePack pack) {
    final IrodoriSampling s = pack.sampling;
    final List<String> missing = pack.missingFiles();
    return <Widget>[
      AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-edit-character'),
            icon: FushiIcons.person,
            showIcon: true,
            title: t.audiobook_tts_voice_pack_character,
            trailing: _secondary(pack.character),
            onTap: () => unawaited(_rename(pack)),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-edit-adapter'),
            icon: FushiIcons.folderOpen,
            showIcon: true,
            title: t.audiobook_tts_voice_pack_adapter,
            subtitle:
                pack.adapterDir ?? t.audiobook_tts_voice_pack_adapter_none,
            subtitleMaxLines: 3,
            onTap: () => unawaited(_pickAdapter(pack)),
            trailing: pack.adapterDir == null
                ? null
                : FushiIconButton(
                    icon: FushiIcons.delete,
                    tooltip: t.audiobook_tts_voice_pack_adapter_clear,
                    onTap: () => _save(pack.copyWith(clearAdapter: true)),
                  ),
          ),
          if (pack.validate().isNotEmpty || missing.isNotEmpty)
            AdaptiveSettingsRow(
              key: const ValueKey<String>('voice-pack-edit-problems'),
              icon: FushiIcons.warning,
              showIcon: true,
              title: irodoriVoicePackSummary(pack, missing),
              titleMaxLines: 3,
              subtitle: missing.isEmpty ? null : missing.join('\n'),
              subtitleMaxLines: 6,
            ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.audiobook_tts_voice_pack_groups,
        children: <Widget>[
          for (int i = 0; i < pack.groups.length; i++)
            AdaptiveSettingsRow(
              key: ValueKey<String>('voice-pack-group-$i'),
              icon: FushiIcons.voice,
              showIcon: true,
              title: pack.groups[i].name,
              subtitle: t.audiobook_tts_voice_pack_group_files(
                count: pack.groups[i].files.length,
              ),
              onTap: () => unawaited(_groupActions(pack, i)),
            ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-group-add'),
            icon: FushiIcons.add,
            showIcon: true,
            title: t.audiobook_tts_voice_pack_group_add,
            subtitle: t.audiobook_tts_voice_pack_group_name_hint,
            subtitleMaxLines: 2,
            onTap: () => unawaited(_addGroup(pack)),
          ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.audiobook_tts_voice_pack_sampling,
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-steps'),
            title: t.audiobook_tts_voice_pack_steps,
            trailing: _secondary('${s.steps}'),
            onTap: () => unawaited(
              _editNumber(
                title: t.audiobook_tts_voice_pack_steps,
                initial: '${s.steps}',
                integer: true,
                apply: (num v) => _save(
                  pack.copyWith(
                    sampling: IrodoriSampling(
                      steps: v.toInt() < 1 ? 1 : v.toInt(),
                      cfgText: s.cfgText,
                      cfgSpeaker: s.cfgSpeaker,
                      seed: s.seed,
                    ),
                  ),
                ),
              ),
            ),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-cfg-text'),
            title: t.audiobook_tts_voice_pack_cfg_text,
            trailing: _secondary('${s.cfgText}'),
            onTap: () => unawaited(
              _editNumber(
                title: t.audiobook_tts_voice_pack_cfg_text,
                initial: '${s.cfgText}',
                integer: false,
                apply: (num v) => _save(
                  pack.copyWith(
                    sampling: IrodoriSampling(
                      steps: s.steps,
                      cfgText: v.toDouble(),
                      cfgSpeaker: s.cfgSpeaker,
                      seed: s.seed,
                    ),
                  ),
                ),
              ),
            ),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-cfg-speaker'),
            title: t.audiobook_tts_voice_pack_cfg_speaker,
            trailing: _secondary('${s.cfgSpeaker}'),
            onTap: () => unawaited(
              _editNumber(
                title: t.audiobook_tts_voice_pack_cfg_speaker,
                initial: '${s.cfgSpeaker}',
                integer: false,
                apply: (num v) => _save(
                  pack.copyWith(
                    sampling: IrodoriSampling(
                      steps: s.steps,
                      cfgText: s.cfgText,
                      cfgSpeaker: v.toDouble(),
                      seed: s.seed,
                    ),
                  ),
                ),
              ),
            ),
          ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('voice-pack-seed'),
            title: t.audiobook_tts_voice_pack_seed,
            trailing: _secondary('${s.seed}'),
            onTap: () => unawaited(
              _editNumber(
                title: t.audiobook_tts_voice_pack_seed,
                initial: '${s.seed}',
                integer: true,
                apply: (num v) => _save(
                  pack.copyWith(
                    sampling: IrodoriSampling(
                      steps: s.steps,
                      cfgText: s.cfgText,
                      cfgSpeaker: s.cfgSpeaker,
                      seed: v.toInt(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final IrodoriVoicePack? pack = _pack;
    return _packScaffold(
      context: context,
      title: pack?.character ?? t.audiobook_tts_voice_pack_title,
      entranceKey: 'voice-pack-editor-entrance',
      sections: pack == null ? const <Widget>[] : _sections(pack),
    );
  }
}
