/// Irodori 声音包（设计 §5）：一个角色的声音 = LoRA adapter 目录（可无）+ 若干组按用途
/// 命名的参考音频 + 采样参数 + 角色名。声音包只记本机路径，app 不复制、不分发任何声音。
///
/// ## 声音 id
///
/// 声音包在选角表（`CastVoiceAssignment`）里与声音预设共用一个字符串 id 空间：
///
/// - `pack:<packId>/<group>`：某个声音包的某组参考音频；
/// - `pack:<packId>`：该声音包的第一组（默认组）。
///
/// `<packId>` 只含 `[A-Za-z0-9_-]`（[IrodoriVoicePackStore.newId] 生成）；`<group>` 是
/// 组名原文（第一个 `/` 之后的全部，可以含中文与 `/`）。预设 id 不会以 `pack:` 开头
/// （预设 id 是时间戳 / `builtin_*`），所以两类 id 不会撞。解析见 [IrodoriPackVoiceId]。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// 声音包 id 的前缀。
const String kIrodoriPackVoicePrefix = 'pack:';

final RegExp _kPackIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// 一个声音包声音 id（`pack:<packId>[/<group>]`）。
class IrodoriPackVoiceId {
  const IrodoriPackVoiceId(this.packId, [this.group]);

  final String packId;

  /// 参考音频组名；null = 默认组（第一组）。
  final String? group;

  /// 是不是声音包 id（不校验包是否存在）。
  static bool isPackVoice(String? voiceId) =>
      voiceId != null && voiceId.startsWith(kIrodoriPackVoicePrefix);

  /// 解析；不是声音包 id 或格式不对返回 null。
  static IrodoriPackVoiceId? parse(String? voiceId) {
    if (voiceId == null || !voiceId.startsWith(kIrodoriPackVoicePrefix)) {
      return null;
    }
    final String rest = voiceId.substring(kIrodoriPackVoicePrefix.length);
    final int slash = rest.indexOf('/');
    final String packId = slash < 0 ? rest : rest.substring(0, slash);
    if (!_kPackIdPattern.hasMatch(packId)) return null;
    if (slash < 0) return IrodoriPackVoiceId(packId);
    final String group = rest.substring(slash + 1);
    return IrodoriPackVoiceId(packId, group.isEmpty ? null : group);
  }

  String get wire => group == null
      ? '$kIrodoriPackVoicePrefix$packId'
      : '$kIrodoriPackVoicePrefix$packId/$group';

  @override
  String toString() => wire;

  @override
  bool operator ==(Object other) =>
      other is IrodoriPackVoiceId &&
      other.packId == packId &&
      other.group == group;

  @override
  int get hashCode => Object.hash(packId, group);
}

/// 一组参考音频（例如「内心」「说出口」）。v4-Large 的说明建议多段短句拼起来当参考，
/// 合计约 30 秒。
class IrodoriRefGroup {
  const IrodoriRefGroup({required this.name, required this.files});

  final String name;

  /// 参考音频的绝对路径（按顺序交给模型）。
  final List<String> files;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'files': files,
  };

  static IrodoriRefGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? name = raw['name'];
    final Object? files = raw['files'];
    if (name is! String || name.trim().isEmpty) return null;
    return IrodoriRefGroup(
      name: name.trim(),
      files: <String>[
        if (files is List)
          for (final Object? f in files)
            if (f is String && f.isNotEmpty) f,
      ],
    );
  }
}

/// 采样参数。默认值是所有者训练 LoRA 时用的推理设置（40 步、文本引导 3.0、说话人
/// 引导 5.0）。[seed] 是这个声音的默认种子（整部作品一个种子，生成任务可以覆盖）。
class IrodoriSampling {
  const IrodoriSampling({
    this.steps = kIrodoriDefaultSteps,
    this.cfgText = kIrodoriDefaultCfgText,
    this.cfgSpeaker = kIrodoriDefaultCfgSpeaker,
    this.seed = 0,
  });

  final int steps;
  final double cfgText;
  final double cfgSpeaker;
  final int seed;

  Map<String, Object?> toJson() => <String, Object?>{
    'steps': steps,
    'cfgText': cfgText,
    'cfgSpeaker': cfgSpeaker,
    'seed': seed,
  };

  static IrodoriSampling fromJson(Object? raw) {
    if (raw is! Map) return const IrodoriSampling();
    final Object? steps = raw['steps'];
    final Object? text = raw['cfgText'];
    final Object? speaker = raw['cfgSpeaker'];
    final Object? seed = raw['seed'];
    return IrodoriSampling(
      steps: steps is int && steps > 0 ? steps : kIrodoriDefaultSteps,
      cfgText: text is num ? text.toDouble() : kIrodoriDefaultCfgText,
      cfgSpeaker: speaker is num
          ? speaker.toDouble()
          : kIrodoriDefaultCfgSpeaker,
      seed: seed is int ? seed : 0,
    );
  }
}

const int kIrodoriDefaultSteps = 40;
const double kIrodoriDefaultCfgText = 3.0;
const double kIrodoriDefaultCfgSpeaker = 5.0;

/// 一个声音包。
class IrodoriVoicePack {
  const IrodoriVoicePack({
    required this.id,
    required this.character,
    required this.groups,
    this.adapterDir,
    this.sampling = const IrodoriSampling(),
    this.revision = 0,
  });

  /// 见 [IrodoriVoicePackStore.newId]。
  final String id;

  /// 角色名（显示用，也是选角时按名字匹配的依据）。
  final String character;

  /// LoRA adapter 目录（含 `adapter_model.safetensors`）；null = 只用底模 + 参考音频。
  final String? adapterDir;

  /// 参考音频组，第一组是默认组。
  final List<IrodoriRefGroup> groups;
  final IrodoriSampling sampling;

  /// 每次编辑自增：进缓存键（换了参考音频或参数，旧的合成结果不再命中）。
  final int revision;

  bool get usesLora => adapterDir != null;

  /// [name] 这一组；null = 默认组（第一组）。没有返回 null。
  IrodoriRefGroup? group(String? name) {
    if (groups.isEmpty) return null;
    if (name == null) return groups.first;
    for (final IrodoriRefGroup g in groups) {
      if (g.name == name) return g;
    }
    return null;
  }

  /// 每组的声音 id（选角下拉的选项）。
  List<IrodoriPackVoiceId> get voiceIds => <IrodoriPackVoiceId>[
    for (final IrodoriRefGroup g in groups) IrodoriPackVoiceId(id, g.name),
  ];

  /// 包本身缺什么（不查磁盘）：空列表 = 结构完整。
  List<IrodoriVoicePackProblem> validate() => <IrodoriVoicePackProblem>[
    if (character.trim().isEmpty) IrodoriVoicePackProblem.noCharacter,
    if (groups.isEmpty) IrodoriVoicePackProblem.noGroups,
    if (groups.any((IrodoriRefGroup g) => g.files.isEmpty))
      IrodoriVoicePackProblem.emptyGroup,
    if (groups.map((IrodoriRefGroup g) => g.name).toSet().length !=
        groups.length)
      IrodoriVoicePackProblem.duplicateGroup,
  ];

  /// 磁盘上找不到的文件 / 目录（参考音频，adapter 目录缺 `adapter_model.*` 也算）。
  List<String> missingFiles() => <String>[
    if (adapterDir case final String dir)
      if (!File(p.join(dir, 'adapter_model.safetensors')).existsSync() &&
          !File(p.join(dir, 'adapter_model.bin')).existsSync())
        dir,
    for (final IrodoriRefGroup g in groups)
      for (final String f in g.files)
        if (!File(f).existsSync()) f,
  ];

  IrodoriVoicePack copyWith({
    String? character,
    String? adapterDir,
    bool clearAdapter = false,
    List<IrodoriRefGroup>? groups,
    IrodoriSampling? sampling,
    int? revision,
  }) => IrodoriVoicePack(
    id: id,
    character: character ?? this.character,
    adapterDir: clearAdapter ? null : (adapterDir ?? this.adapterDir),
    groups: groups ?? this.groups,
    sampling: sampling ?? this.sampling,
    revision: revision ?? this.revision,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'character': character,
    if (adapterDir != null) 'adapter': adapterDir,
    'groups': <Object?>[for (final IrodoriRefGroup g in groups) g.toJson()],
    'sampling': sampling.toJson(),
    'revision': revision,
  };

  static IrodoriVoicePack? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? character = raw['character'];
    final Object? adapter = raw['adapter'];
    final Object? groups = raw['groups'];
    final Object? revision = raw['revision'];
    if (id is! String || !_kPackIdPattern.hasMatch(id)) return null;
    return IrodoriVoicePack(
      id: id,
      character: character is String ? character : '',
      adapterDir: adapter is String && adapter.isNotEmpty ? adapter : null,
      groups: <IrodoriRefGroup>[
        if (groups is List)
          for (final Object? g in groups) ?IrodoriRefGroup.fromJson(g),
      ],
      sampling: IrodoriSampling.fromJson(raw['sampling']),
      revision: revision is int ? revision : 0,
    );
  }
}

enum IrodoriVoicePackProblem {
  noCharacter,
  noGroups,
  emptyGroup,
  duplicateGroup,
}

/// 声音包清单：一个 JSON 文件（设备本地，路径只在本机有意义）。读写都是同步的小
/// 文件 IO（清单只有几 KB）。
class IrodoriVoicePackStore {
  IrodoriVoicePackStore(this.file);

  final File file;

  /// 读清单；文件不在 / 坏了返回空（坏文件不覆盖，等下一次保存）。
  List<IrodoriVoicePack> load() {
    try {
      if (!file.existsSync()) return const <IrodoriVoicePack>[];
      final Object? raw = jsonDecode(file.readAsStringSync());
      final Object? packs = raw is Map ? raw['packs'] : null;
      if (packs is! List) return const <IrodoriVoicePack>[];
      return <IrodoriVoicePack>[
        for (final Object? p in packs) ?IrodoriVoicePack.fromJson(p),
      ];
    } on FormatException {
      return const <IrodoriVoicePack>[];
    } on FileSystemException {
      return const <IrodoriVoicePack>[];
    }
  }

  /// 原子写（先写临时文件再改名），写坏不会丢旧清单。
  void save(List<IrodoriVoicePack> packs) {
    file.parent.createSync(recursive: true);
    final File tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'version': 1,
        'packs': <Object?>[for (final IrodoriVoicePack e in packs) e.toJson()],
      }),
      flush: true,
    );
    tmp.renameSync(file.path);
  }

  IrodoriVoicePack? byId(String id) {
    for (final IrodoriVoicePack e in load()) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 新增或替换（同 id）。替换时 [IrodoriVoicePack.revision] 自增。返回存下的那份。
  IrodoriVoicePack upsert(IrodoriVoicePack pack) {
    final List<IrodoriVoicePack> packs = load().toList();
    final int i = packs.indexWhere((IrodoriVoicePack e) => e.id == pack.id);
    final IrodoriVoicePack stored = i < 0
        ? pack
        : pack.copyWith(revision: max(pack.revision, packs[i].revision) + 1);
    if (i < 0) {
      packs.add(stored);
    } else {
      packs[i] = stored;
    }
    save(packs);
    return stored;
  }

  /// 删掉 [id]；不存在返回 false。
  bool remove(String id) {
    final List<IrodoriVoicePack> packs = load().toList();
    final int before = packs.length;
    packs.removeWhere((IrodoriVoicePack e) => e.id == id);
    if (packs.length == before) return false;
    save(packs);
    return true;
  }

  /// [voiceId] 指向的声音包与组；不是声音包 id、包不存在或组不存在返回 null。
  ({IrodoriVoicePack pack, IrodoriRefGroup group})? resolve(String? voiceId) =>
      resolveIrodoriPackVoice(load(), voiceId);

  /// 新声音包 id：`p` + 毫秒时间戳（36 进制）+ 4 位随机。
  static String newId({DateTime? now, Random? random}) {
    final int ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final int r = (random ?? Random()).nextInt(36 * 36 * 36 * 36);
    return 'p${ms.toRadixString(36)}${r.toRadixString(36).padLeft(4, '0')}';
  }
}

/// 纯函数版 [IrodoriVoicePackStore.resolve]。
({IrodoriVoicePack pack, IrodoriRefGroup group})? resolveIrodoriPackVoice(
  Iterable<IrodoriVoicePack> packs,
  String? voiceId,
) {
  final IrodoriPackVoiceId? id = IrodoriPackVoiceId.parse(voiceId);
  if (id == null) return null;
  for (final IrodoriVoicePack pack in packs) {
    if (pack.id != id.packId) continue;
    final IrodoriRefGroup? group = pack.group(id.group);
    return group == null ? null : (pack: pack, group: group);
  }
  return null;
}

/// 不挂 LoRA 的声音在短句上的给定时长（秒）；其余返回 null（交给时长预测）。
///
/// 实测（第 2 卷整卷）：不挂 LoRA 时时长预测给 20 字以内的短句 2.5～6 秒，模型会把这句
/// 念两遍（首轮 49 条里 19 条，挂 LoRA 的 0 条）。按挂 LoRA 声音的实测语速（3 字约
/// 1.0 秒、5 字 1.3 秒、10 字 2.0 秒）直接给定 `0.55 + 0.15 × 字数` 秒后消失。字数不计
/// 空白、标点、符号与长音符「ー」（[irodoriSpokenCharCount]）。没有可念的字时返回 null。
///
/// 这是短句定长规则的唯一实现：声音包 provider、批处理 worker 的 [IrodoriBatchItem]
/// 和漫画生成端（`manga_audio_render_backend.dart`）都调它。
double? irodoriManualSeconds(String text, {required bool lora}) {
  if (lora) return null;
  final int chars = irodoriSpokenCharCount(text);
  if (chars == 0 || chars > kIrodoriShortLineChars) return null;
  return ((0.55 + 0.15 * chars) * 100).round() / 100;
}

/// 短句规则的上限字数。
const int kIrodoriShortLineChars = 20;

/// 念出来的字数：去掉空白、Unicode 标点 / 符号，以及参考实现同样不计的长音符「ー」。
int irodoriSpokenCharCount(String text) => text.runes.where((int r) {
  final String c = String.fromCharCode(r);
  return c.trim().isNotEmpty && c != 'ー' && !_kIrodoriNonSpoken.hasMatch(c);
}).length;

final RegExp _kIrodoriNonSpoken = RegExp(r'[\p{P}\p{S}]', unicode: true);

/// 模型单条上限 30 秒；调用方按句末把长段切成不超过这个字数的片段。
const int kIrodoriMaxLineChars = 70;
