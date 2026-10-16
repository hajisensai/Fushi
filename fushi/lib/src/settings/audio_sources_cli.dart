/// 「管理音频来源」对话框在控制通道上的等价操作。
///
/// 列表 = `AppModel.audioSourceConfigs`（顺序即优先级），每次改动都按对话框关闭时
/// 同一种方式整表落盘：`AppModel.setAudioSourceConfigs(..., scope: syncEverywhere)`
/// （移除的本地库照常向其它设备传播删除，接收端逐条确认）。编辑规则（URL 校验、
/// 互联源唯一、重排、恢复默认）与对话框共用 `audio_source_list_edit.dart`。
///
/// 记录 id：`fushi_remote` / `remote:<url>` / `local:<库路径>`；同值重复的行在后面
/// 补 `#2`、`#3`。
library;

import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/audio_source_list_edit.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';

/// 列表里每一行的记录 id（见库注释）。
List<String> audioSourceCliIds(List<AudioSourceConfig> sources) {
  final Map<String, int> seen = <String, int>{};
  return <String>[
    for (final AudioSourceConfig source in sources)
      () {
        final String base = switch (source.kind) {
          AudioSourceKind.fushiRemote => 'fushi_remote',
          AudioSourceKind.remoteAudio => 'remote:${source.url ?? ''}',
          AudioSourceKind.localAudio => 'local:${source.path ?? ''}',
        };
        final int n = (seen[base] ?? 0) + 1;
        seen[base] = n;
        return n == 1 ? base : '$base#$n';
      }(),
  ];
}

String _kindToken(AudioSourceKind kind) => switch (kind) {
  AudioSourceKind.fushiRemote => 'fushi_remote',
  AudioSourceKind.remoteAudio => 'remote',
  AudioSourceKind.localAudio => 'local',
};

Map<String, Object?> _record(AudioSourceConfig source, String id, int index) =>
    <String, Object?>{
      'id': id,
      'position': index,
      'kind': _kindToken(source.kind),
      'enabled': source.enabled,
      if (source.label != null) 'label': source.label,
      if (source.url != null) 'url': source.url,
      if (source.path != null) 'path': source.path,
    };

bool _parseBool(String raw, String name) {
  switch (raw.trim().toLowerCase()) {
    case 'true' || '1' || 'yes' || 'on':
      return true;
    case 'false' || '0' || 'no' || 'off':
      return false;
  }
  throw ArgumentError('$name 必须是 true / false');
}

int _parsePosition(String raw) {
  final int? value = int.tryParse(raw.trim());
  if (value == null || value < 0) {
    throw ArgumentError('position 必须是 ≥0 的整数（0 = 最高优先级）');
  }
  return value;
}

String _validRemoteUrl(String raw) {
  // 存归一化后的值（同对话框）：校验折了全角，落库的也必须是折过的。
  final String url = normalizeUrlInput(raw);
  if (!isValidRemoteAudioUrl(url)) {
    throw ArgumentError('远端音频地址必须是 http(s) 链接，且含 {term} 或 {reading} 占位符');
  }
  return url;
}

int _indexOfId(List<AudioSourceConfig> sources, String id) {
  final int index = audioSourceCliIds(sources).indexOf(id);
  if (index < 0) {
    throw ArgumentError(
      '没有音频来源「$id」（config items lookup.audio_sources.items ls）',
    );
  }
  return index;
}

Future<void> _save(
  AppModel appModel,
  List<AudioSourceConfig> next, {
  Map<String, List<LocalAudioSourcePref>> sourcesByPath =
      const <String, List<LocalAudioSourcePref>>{},
}) => appModel.setAudioSourceConfigs(
  next,
  sourcesByPath: sourcesByPath,
  scope: DeleteScope.syncEverywhere,
);

/// 把本机音频库文件导入成一个 localAudio 源（同对话框「导入本地音频库」）。
Future<AudioSourceConfig> _importLocalDb(
  AppModel appModel,
  String path, {
  required String? label,
  required bool reference,
}) async {
  if (!p.isAbsolute(path)) throw ArgumentError('path 必须是绝对路径');
  try {
    final LocalAudioDbEntry entry = await appModel.importLocalAudioDbFile(
      path,
      displayName: label ?? p.basename(path),
      reference: reference,
    );
    return AudioSourceConfig.localAudio(
      label: entry.displayName,
      path: entry.path,
      enabled: true,
    );
  } on InvalidLocalAudioDbException {
    throw ArgumentError('「$path」不是可用的本地音频库（Yomitan 本地音频服务器的 .db）');
  }
}

/// 当前列表（记录形式）。
List<Map<String, Object?>> listAudioSourcesForCli(AppModel appModel) {
  final List<AudioSourceConfig> sources = appModel.audioSourceConfigs;
  final List<String> ids = audioSourceCliIds(sources);
  return <Map<String, Object?>>[
    for (int i = 0; i < sources.length; i++) _record(sources[i], ids[i], i),
  ];
}

Map<String, Object?> _recordOf(AppModel appModel, AudioSourceConfig source) {
  final List<AudioSourceConfig> sources = appModel.audioSourceConfigs;
  final int index = sources.indexOf(source);
  final List<String> ids = audioSourceCliIds(sources);
  return index < 0
      ? _record(source, '', -1)
      : _record(sources[index], ids[index], index);
}

/// 新增一个来源：`kind=remote url=…` / `kind=fushi_remote` /
/// `kind=local path=… [reference=true]`；默认插到最前（同对话框）。
Future<Map<String, Object?>> addAudioSourceForCli(
  AppModel appModel,
  Map<String, String> fields,
) async {
  final List<AudioSourceConfig> sources = appModel.audioSourceConfigs;
  final String kind =
      fields['kind'] ??
      (fields['path'] != null
          ? 'local'
          : fields['url'] != null
          ? 'remote'
          : '');
  final String? label = fields['label']?.trim().isEmpty ?? true
      ? null
      : fields['label']!.trim();
  AudioSourceConfig added;
  switch (kind) {
    case 'remote':
      final String? rawUrl = fields['url'];
      if (rawUrl == null) throw ArgumentError('kind=remote 需要 url');
      final String url = _validRemoteUrl(rawUrl);
      if (sources.any(
        (AudioSourceConfig s) =>
            s.kind == AudioSourceKind.remoteAudio && s.url == url,
      )) {
        throw ArgumentError('已有同一个远端地址');
      }
      added = AudioSourceConfig.remoteAudio(url: url, label: label);
    case 'fushi_remote':
      if (hasFushiRemoteAudioSource(sources)) {
        throw ArgumentError('已经有 Fushi 互联源（只能有一条）');
      }
      added = AudioSourceConfig.fushiRemote();
    case 'local':
      final String? path = fields['path'];
      if (path == null) throw ArgumentError('kind=local 需要 path（音频库文件）');
      added = await _importLocalDb(
        appModel,
        path,
        label: label,
        reference: fields['reference'] == null
            ? false
            : _parseBool(fields['reference']!, 'reference'),
      );
    default:
      throw ArgumentError('kind 取 remote / fushi_remote / local');
  }
  if (fields['enabled'] != null) {
    added = added.copyWith(enabled: _parseBool(fields['enabled']!, 'enabled'));
  }
  final int position = fields['position'] == null
      ? 0
      : _parsePosition(fields['position']!);
  final List<AudioSourceConfig> next = List<AudioSourceConfig>.of(sources)
    ..insert(position.clamp(0, sources.length), added);
  await _save(appModel, next);
  return _recordOf(appModel, added);
}

/// 改一个来源：`enabled` / `label` / `url`（远端）/ `path`（本地：换库文件，保留
/// 子来源偏好，同对话框「重新选择」）/ `position`（挪到第几位）。
Future<Map<String, Object?>> updateAudioSourceForCli(
  AppModel appModel,
  String id,
  Map<String, String> fields,
) async {
  List<AudioSourceConfig> next = List<AudioSourceConfig>.of(
    appModel.audioSourceConfigs,
  );
  int index = _indexOfId(next, id);
  AudioSourceConfig source = next[index];
  final Map<String, List<LocalAudioSourcePref>> prefs =
      <String, List<LocalAudioSourcePref>>{};
  if (fields['url'] != null) {
    if (source.kind != AudioSourceKind.remoteAudio) {
      throw ArgumentError('只有远端来源有 url');
    }
    source = source.copyWith(url: _validRemoteUrl(fields['url']!));
  }
  if (fields['label'] != null) {
    if (source.kind == AudioSourceKind.fushiRemote) {
      throw ArgumentError('Fushi 互联源没有显示名');
    }
    source = source.copyWith(label: fields['label']!.trim());
  }
  if (fields['path'] != null) {
    if (source.kind != AudioSourceKind.localAudio) {
      throw ArgumentError('只有本地来源有 path');
    }
    final AudioSourceConfig replacement = await _importLocalDb(
      appModel,
      fields['path']!,
      label: source.label,
      reference: fields['reference'] == null
          ? false
          : _parseBool(fields['reference']!, 'reference'),
    );
    prefs[replacement.path!] = appModel.sourcePrefsForLocalDb(source.path!);
    source = source.copyWith(path: replacement.path);
  }
  if (fields['enabled'] != null) {
    source = source.copyWith(
      enabled: _parseBool(fields['enabled']!, 'enabled'),
    );
  }
  next[index] = source;
  if (fields['position'] != null) {
    next = moveAudioSource(next, index, _parsePosition(fields['position']!));
    index = next.indexOf(source);
  }
  await _save(appModel, next, sourcesByPath: prefs);
  return _recordOf(appModel, source);
}

/// 删一个来源（互联源在对话框里删不掉，只能关闭）。
Future<void> removeAudioSourceForCli(AppModel appModel, String id) async {
  final List<AudioSourceConfig> next = List<AudioSourceConfig>.of(
    appModel.audioSourceConfigs,
  );
  final int index = _indexOfId(next, id);
  if (next[index].kind == AudioSourceKind.fushiRemote) {
    throw ArgumentError('Fushi 互联源不能删除，用 enabled=false 关闭');
  }
  next.removeAt(index);
  await _save(appModel, next);
}

/// 「重置」（同对话框底部按钮）。
Future<List<Map<String, Object?>>> resetAudioSourcesForCli(
  AppModel appModel,
) async {
  await _save(
    appModel,
    resetAudioSourcesToDefaults(
      appModel.audioSourceConfigs,
      ankiLocalAudioUrl: AppModel.ankiLocalAudioUrl,
    ),
  );
  return listAudioSourcesForCli(appModel);
}

/// 本地音频库的子来源（优先级序 + 逐源启用，同「编辑本地子来源」对话框）。
/// [spec] 为 null = 只查询；否则写成 `name1,!name2,…`（`!` = 停用，顺序即优先级）。
Future<Map<String, Object?>> localAudioSubSourcesForCli(
  AppModel appModel, {
  required String path,
  String? spec,
}) async {
  final bool known = appModel.audioSourceConfigs.any(
    (AudioSourceConfig s) =>
        s.kind == AudioSourceKind.localAudio && s.path == path,
  );
  if (!known) {
    throw ArgumentError('没有路径为「$path」的本地音频库（用 items ls 里 local 行的 path）');
  }
  final List<String> available = await appModel.listLocalAudioSources(path);
  if (spec != null) {
    final List<LocalAudioSourcePref> prefs = <LocalAudioSourcePref>[];
    for (final String raw in spec.split(',')) {
      final String token = raw.trim();
      if (token.isEmpty) continue;
      final bool disabled = token.startsWith('!');
      final String name = disabled ? token.substring(1).trim() : token;
      if (!available.contains(name)) {
        throw ArgumentError('库里没有子来源「$name」；可用：${available.join(', ')}');
      }
      if (prefs.any((LocalAudioSourcePref e) => e.name == name)) {
        throw ArgumentError('子来源「$name」写了两次');
      }
      prefs.add(LocalAudioSourcePref(name: name, enabled: !disabled));
    }
    await appModel.setLocalAudioDbSources(path, prefs);
  }
  return <String, Object?>{
    'path': path,
    'available': available,
    'saved': <Map<String, Object?>>[
      for (final LocalAudioSourcePref pref in appModel.sourcePrefsForLocalDb(
        path,
      ))
        pref.toJson(),
    ],
  };
}

/// `config items lookup.audio_sources.items …` 的列表操作。
final SettingsCliList audioSourcesCliList = SettingsCliList(
  list: (SettingsContext c) async => listAudioSourcesForCli(c.appModel),
  add: (SettingsContext c, Map<String, String> fields) =>
      addAudioSourceForCli(c.appModel, fields),
  update: (SettingsContext c, String id, Map<String, String> fields) =>
      updateAudioSourceForCli(c.appModel, id, fields),
  remove: (SettingsContext c, String id) =>
      removeAudioSourceForCli(c.appModel, id),
  fields: const <SettingsCliParam>[
    SettingsCliParam(
      'kind',
      help: 'add：remote / fushi_remote / local（缺省按给的 url / path 推断）',
      required: false,
    ),
    SettingsCliParam(
      'url',
      help: '远端地址，含 {term} / {reading}，如 https://…?term={term}',
      required: false,
    ),
    SettingsCliParam('label', help: '显示名', required: false),
    SettingsCliParam(
      'path',
      help: '本地音频库文件（.db）；set 时 = 换成另一个库文件',
      required: false,
      path: true,
    ),
    SettingsCliParam(
      'reference',
      help: 'true = 引用原文件不复制（缺省复制进库目录）',
      required: false,
    ),
    SettingsCliParam('enabled', help: 'true / false', required: false),
    SettingsCliParam(
      'position',
      help: '放到第几位（0 = 最高优先级；add 缺省 0）',
      required: false,
    ),
  ],
);
