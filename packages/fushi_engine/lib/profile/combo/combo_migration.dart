/// 「组合」一次性迁移（拍板台 design-combo-node-split 阶段 3、design-srs-shared-library §4.2）：
/// 存量整份快照 → 「默认组合 + 只记被拆叶子的组合」的规划（纯函数，无 I/O）。
///
/// 规划只吃「每份 Profile 此刻的行」与绑定表，产出「要整份重写哪些 Profile 的行」+ 迁移报告；
/// 落库、备份、快照激活配置由 app 的 `ProfileRepository` 做。规划是**幂等的归一**，不只是一次性
/// 升级：任何时候库里出现「没有默认组合」「存量快照混在组合格式里」（旧备份恢复 / 合并导入带进
/// 来的）「两个默认组合」（两边各有默认的合并），再跑一次都会收敛到唯一默认 + 其余组合格式。
///
/// 设计见 `docs/specs/2026-11-23-combo-settings-tree-design.md` §3.3、§4.2。
library;

import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

/// 复习库归属叶子的合成键与取值（与 app `fushi_settings_tree.dart` 同名常量同值；那边登记
/// 叶子，这里只按值读写，避免引擎反向依赖 app）。
const String kComboSrsLibraryLeafId = 'srs.library';
const String kComboSrsLibrarySettingKey = 'srs_library';
const String kComboSrsLibraryOwnValue = 'own';

/// 规划的输入：一份 Profile 此刻的全部 `profile_settings` 行。
class ComboMigrationProfile {
  const ComboMigrationProfile({
    required this.id,
    required this.uid,
    required this.name,
    required this.rows,
  });

  final int id;

  /// `profiles.uid`（复习集合身份）。
  final String uid;
  final String name;

  /// 全部行（旧 category 已按今天的 pref 键归一，含 `combo` 行）。
  final Map<SettingKey, String> rows;
}

/// 规划的输入：三张绑定表（值 = Profile id）。
class ComboMigrationBindings {
  const ComboMigrationBindings({
    this.mediaType = const <String, int>{},
    this.language = const <String, int>{},
    this.work = const <String, int>{},
  });

  /// 媒体类型落库值（`ProfileMediaKind.dbValue`）→ Profile。
  final Map<String, int> mediaType;

  /// 归一后的语言标签 → Profile。
  final Map<String, int> language;

  /// 作品 uid → Profile。
  final Map<String, int> work;
}

/// 一个组合迁移后单独设置了哪些叶子。
class ComboMigrationEntry {
  const ComboMigrationEntry({required this.name, required this.splitLeaves});

  factory ComboMigrationEntry.fromJson(Map<String, Object?> json) =>
      ComboMigrationEntry(
        name: json['name']! as String,
        splitLeaves: <String>[
          for (final Object? l in json['leaves']! as List<Object?>)
            l! as String,
        ],
      );

  final String name;

  /// 树上声明顺序。空 = 与默认组合完全相同（全部继承）。
  final List<String> splitLeaves;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'leaves': splitLeaves,
  };
}

/// 「同一份内容同时命中语言与媒体类型绑定」且迁移后生效值变了的叶子（旧顺序语言高于媒体类型，
/// 新顺序媒体类型高于语言，§2.2 的有意行为变化）。
class ComboBindingConflict {
  const ComboBindingConflict({
    required this.languageTag,
    required this.mediaType,
    required this.languageProfile,
    required this.mediaTypeProfile,
    required this.leaves,
  });

  factory ComboBindingConflict.fromJson(Map<String, Object?> json) =>
      ComboBindingConflict(
        languageTag: json['language']! as String,
        mediaType: json['mediaType']! as String,
        languageProfile: json['languageProfile']! as String,
        mediaTypeProfile: json['mediaTypeProfile']! as String,
        leaves: <String>[
          for (final Object? l in json['leaves']! as List<Object?>)
            l! as String,
        ],
      );

  final String languageTag;

  /// `ProfileMediaKind.dbValue`。
  final String mediaType;
  final String languageProfile;
  final String mediaTypeProfile;

  /// 生效值改为取媒体类型那份的叶子（树上声明顺序）。
  final List<String> leaves;

  Map<String, Object?> toJson() => <String, Object?>{
    'language': languageTag,
    'mediaType': mediaType,
    'languageProfile': languageProfile,
    'mediaTypeProfile': mediaTypeProfile,
    'leaves': leaves,
  };
}

/// 某组合在某层的绑定里拆了该层不允许拆的叶子：解析时被忽略（旧版在作品层同样不接管它们）。
class ComboIgnoredSplitEntry {
  const ComboIgnoredSplitEntry({
    required this.profile,
    required this.scope,
    required this.bindings,
    required this.leaves,
  });

  factory ComboIgnoredSplitEntry.fromJson(Map<String, Object?> json) =>
      ComboIgnoredSplitEntry(
        profile: json['profile']! as String,
        scope: ComboScope.values.byName(json['scope']! as String),
        bindings: json['bindings']! as int,
        leaves: <String>[
          for (final Object? l in json['leaves']! as List<Object?>)
            l! as String,
        ],
      );

  final String profile;
  final ComboScope scope;

  /// 这个组合在 [scope] 层上有几条绑定。
  final int bindings;
  final List<String> leaves;

  Map<String, Object?> toJson() => <String, Object?>{
    'profile': profile,
    'scope': scope.name,
    'bindings': bindings,
    'leaves': leaves,
  };
}

/// 复习库迁移的结论（§4.2）。
class ComboSrsLibraryDecision {
  const ComboSrsLibraryDecision({
    required this.sharedProfile,
    required this.ownProfiles,
  });

  factory ComboSrsLibraryDecision.fromJson(Map<String, Object?> json) =>
      ComboSrsLibraryDecision(
        sharedProfile: json['shared']! as String,
        ownProfiles: <String>[
          for (final Object? n in json['own']! as List<Object?>) n! as String,
        ],
      );

  /// 共享复习库用的是哪份 Profile 的复习数据（`srs_shared_uid` 指向它）。
  final String sharedProfile;

  /// 各自都有复习数据、迁移后拆成独立复习库的组合。
  final List<String> ownProfiles;

  Map<String, Object?> toJson() => <String, Object?>{
    'shared': sharedProfile,
    'own': ownProfiles,
  };
}

/// 迁移报告（首次启动提示一次，配置页可重看）。可 JSON 往返，存进本机偏好。
class ComboMigrationReport {
  const ComboMigrationReport({
    required this.defaultName,
    required this.combos,
    this.conflicts = const <ComboBindingConflict>[],
    this.ignored = const <ComboIgnoredSplitEntry>[],
    this.srs,
  });

  /// 读坏 / 版本不认识时返回 null（报告只是告知，读不懂就不显示，不阻断任何东西）。
  static ComboMigrationReport? tryParse(Map<String, Object?> json) {
    try {
      if (json['v'] != kVersion) return null;
      final Object? srs = json['srs'];
      return ComboMigrationReport(
        defaultName: json['default']! as String,
        combos: <ComboMigrationEntry>[
          for (final Object? e in json['combos']! as List<Object?>)
            ComboMigrationEntry.fromJson(e! as Map<String, Object?>),
        ],
        conflicts: <ComboBindingConflict>[
          for (final Object? e in json['conflicts']! as List<Object?>)
            ComboBindingConflict.fromJson(e! as Map<String, Object?>),
        ],
        ignored: <ComboIgnoredSplitEntry>[
          for (final Object? e in json['ignored']! as List<Object?>)
            ComboIgnoredSplitEntry.fromJson(e! as Map<String, Object?>),
        ],
        srs: srs == null
            ? null
            : ComboSrsLibraryDecision.fromJson(srs as Map<String, Object?>),
      );
    } on Object {
      return null;
    }
  }

  static const int kVersion = 1;

  /// 默认组合的名字。
  final String defaultName;

  /// 迁移成组合格式的每份 Profile（不含默认组合）。
  final List<ComboMigrationEntry> combos;
  final List<ComboBindingConflict> conflicts;
  final List<ComboIgnoredSplitEntry> ignored;

  /// 复习库结论；null = 还没定（复习库当时打不开，下次能打开时补定）。
  final ComboSrsLibraryDecision? srs;

  ComboMigrationReport withSrs(ComboSrsLibraryDecision decision) =>
      ComboMigrationReport(
        defaultName: defaultName,
        combos: combos,
        conflicts: conflicts,
        ignored: ignored,
        srs: decision,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'v': kVersion,
    'default': defaultName,
    'combos': <Object?>[for (final ComboMigrationEntry e in combos) e.toJson()],
    'conflicts': <Object?>[
      for (final ComboBindingConflict c in conflicts) c.toJson(),
    ],
    'ignored': <Object?>[
      for (final ComboIgnoredSplitEntry e in ignored) e.toJson(),
    ],
    if (srs != null) 'srs': srs!.toJson(),
  };
}

/// 规划结果。
class ComboMigrationPlan {
  ComboMigrationPlan({
    required this.defaultId,
    required Map<int, Map<SettingKey, String>> rewrites,
    required this.report,
    required this.srs,
  }) : rewrites = Map<int, Map<SettingKey, String>>.unmodifiable(rewrites);

  /// 迁移后的默认组合。
  final int defaultId;

  /// 要整份替换行的 Profile → 新的全部行。不在其中的 Profile 一行不动。
  final Map<int, Map<SettingKey, String>> rewrites;

  /// 这次把存量快照 / 多余的默认组合改写成了组合格式时才有（只改复习库归属不出报告）。
  final ComboMigrationReport? report;

  /// 这次定下的复习库结论；null = 之前已定或这次定不了。
  final ComboSrsLibraryDecision? srs;

  bool get isNoop => rewrites.isEmpty;
}

class _Decoded {
  _Decoded(this.profile, this.hasRoleRow, this.decoded);

  final ComboMigrationProfile profile;
  final bool hasRoleRow;
  final DecodedComboRows decoded;

  ComboRole? get role => decoded.role;

  /// 有 `role` 行但值不认识：更新版本写的格式，本版本一行不碰。
  bool get isForeign => hasRoleRow && decoded.role == null;
  bool get isLegacy => !hasRoleRow;
}

/// 规划一次归一（见库文档）。
///
/// * [preferredDefaultIds]：选默认组合的先后（`profile_fallback_id`、`active_profile_id`）；
///   都不中时取 id 最小的。已有默认组合时只在已有的里挑（多个时其余降级）。
/// * [srsUidsWithData]：有复习数据的 Profile uid；null = 复习库此刻读不了，复习库结论留到
///   下次（默认组合不写 `srs_shared_uid`，即「没定」的标记）。只有一份 Profile 时不需要它。
ComboMigrationPlan planComboMigration({
  required SettingsTree tree,
  required List<ComboMigrationProfile> profiles,
  required List<int> preferredDefaultIds,
  ComboMigrationBindings bindings = const ComboMigrationBindings(),
  Set<String>? srsUidsWithData,
}) {
  final List<_Decoded> all = <_Decoded>[
    for (final ComboMigrationProfile p
        in List<ComboMigrationProfile>.of(profiles)
          ..sort((ComboMigrationProfile a, ComboMigrationProfile b) {
            return a.id.compareTo(b.id);
          }))
      _Decoded(
        p,
        p.rows.containsKey(
          const SettingKey(kComboSyntheticCategory, kComboRoleKey),
        ),
        decodeComboRows(tree, p.rows),
      ),
  ];
  final List<_Decoded> known = <_Decoded>[
    for (final _Decoded d in all)
      if (!d.isForeign) d,
  ];
  if (known.isEmpty) {
    return ComboMigrationPlan(
      defaultId: all.isEmpty ? -1 : all.first.profile.id,
      rewrites: const <int, Map<SettingKey, String>>{},
      report: null,
      srs: null,
    );
  }

  // ── 选默认组合 ──
  final List<_Decoded> defaults = <_Decoded>[
    for (final _Decoded d in known)
      if (d.role == ComboRole.defaults) d,
  ];
  _Decoded pick(List<_Decoded> pool) {
    for (final int id in preferredDefaultIds) {
      for (final _Decoded d in pool) {
        if (d.profile.id == id) return d;
      }
    }
    return pool.first;
  }

  final List<_Decoded> legacy = <_Decoded>[
    for (final _Decoded d in known)
      if (d.isLegacy) d,
  ];
  final _Decoded keep = defaults.isNotEmpty
      ? pick(defaults)
      : pick(legacy.isNotEmpty ? legacy : known);
  // 默认组合的全量值。被提升的组合格式 Profile（库里只剩组合格式、没有默认——坏状态）只有
  // 它被拆叶子的值；其余叶子在默认层「未设置」，走代码默认值。
  // 默认组合的复习库归属恒为共享（它就是共享库的宿主），不带被提升组合原来的 `own`。
  final Map<SettingKey, String> base = Map<SettingKey, String>.of(
    keep.decoded.values,
  )..remove(_srsLibraryKey);

  final Map<int, Map<SettingKey, String>> rewrites =
      <int, Map<SettingKey, String>>{};
  final Map<int, ComboDocument> documents = <int, ComboDocument>{};
  final List<ComboMigrationEntry> entries = <ComboMigrationEntry>[];
  String? sharedUid = keep.decoded.srsSharedUid;

  for (final _Decoded d in known) {
    if (identical(d, keep)) continue;
    if (d.isLegacy || d.role == ComboRole.defaults) {
      ComboDocument doc = diffAgainstDefaults(
        tree: tree,
        defaults: base,
        snapshot: d.decoded.values,
      );
      // 降级的默认组合：它的共享库不是留下那份的共享库时，它自己的复习数据保持独立。
      final String? itsShared = d.decoded.srsSharedUid;
      if (d.role == ComboRole.defaults &&
          itsShared != null &&
          itsShared != sharedUid) {
        doc = _withOwnLibrary(doc);
      }
      documents[d.profile.id] = doc;
      entries.add(
        ComboMigrationEntry(
          name: d.profile.name,
          splitLeaves: _inTreeOrder(tree, doc.splitLeafIds),
        ),
      );
    } else {
      documents[d.profile.id] = d.decoded.document;
    }
  }
  final Set<int> converted = <int>{
    for (final _Decoded d in known)
      if (!identical(d, keep) && (d.isLegacy || d.role == ComboRole.defaults))
        d.profile.id,
  };
  final bool promoteKeep = keep.role != ComboRole.defaults;

  // ── 复习库（§4.2）：默认组合还没有 `srs_shared_uid` = 还没定 ──
  ComboSrsLibraryDecision? srsDecision;
  final Set<int> ownAdded = <int>{};
  if (sharedUid == null) {
    String? decidedShared;
    final List<_Decoded> withData = <_Decoded>[];
    if (known.length == 1) {
      decidedShared = keep.profile.uid;
    } else if (srsUidsWithData != null) {
      for (final _Decoded d in known) {
        if (srsUidsWithData.contains(d.profile.uid)) withData.add(d);
      }
      if (withData.length <= 1) {
        // 只有一份有复习数据（不一定是默认组合）：共享库就用它那份，不移动任何复习行。
        decidedShared = withData.isEmpty
            ? keep.profile.uid
            : withData.single.profile.uid;
        withData.clear();
      } else {
        // 多份各有数据：默认组合那份当共享库，其余有数据的各自拆出独立复习库，数据不合并。
        decidedShared = keep.profile.uid;
        withData.removeWhere((_Decoded d) => identical(d, keep));
      }
    }
    if (decidedShared != null) {
      sharedUid = decidedShared;
      for (final _Decoded d in withData) {
        final ComboDocument doc = documents[d.profile.id]!;
        if (doc.splits[kComboSrsLibraryLeafId]?[_srsLibraryKey] ==
            kComboSrsLibraryOwnValue) {
          continue;
        }
        documents[d.profile.id] = _withOwnLibrary(doc);
        ownAdded.add(d.profile.id);
      }
      srsDecision = ComboSrsLibraryDecision(
        sharedProfile: <_Decoded>[
          for (final _Decoded d in known)
            if (d.profile.uid == decidedShared) d,
        ].first.profile.name,
        ownProfiles: <String>[
          for (final _Decoded d in withData) d.profile.name,
        ],
      );
    }
  }

  // ── 产出要重写的行 ──
  if (promoteKeep || srsDecision != null) {
    rewrites[keep.profile.id] = <SettingKey, String>{
      ...base,
      const SettingKey(kComboSyntheticCategory, kComboRoleKey):
          ComboRole.defaults.wire,
      if (sharedUid != null)
        const SettingKey(kComboSyntheticCategory, kComboSrsSharedUidKey):
            sharedUid,
    };
  }
  for (final _Decoded d in known) {
    final int id = d.profile.id;
    if (identical(d, keep)) continue;
    if (!converted.contains(id) && !ownAdded.contains(id)) continue;
    final ComboRole role = d.role == ComboRole.workLocal
        ? ComboRole.workLocal
        : ComboRole.named;
    rewrites[id] = encodeComboRows(tree, documents[id]!, role: role);
  }

  ComboMigrationReport? report;
  if (converted.isNotEmpty || promoteKeep && known.length > 1) {
    report = ComboMigrationReport(
      defaultName: keep.profile.name,
      combos: entries,
      conflicts: _conflicts(
        tree: tree,
        base: base,
        keepId: keep.profile.id,
        documents: documents,
        names: <int, String>{
          for (final _Decoded d in known) d.profile.id: d.profile.name,
        },
        bindings: bindings,
      ),
      ignored: _ignoredSplits(
        tree: tree,
        keepId: keep.profile.id,
        documents: documents,
        names: <int, String>{
          for (final _Decoded d in known) d.profile.id: d.profile.name,
        },
        bindings: bindings,
      ),
      srs: srsDecision,
    );
  }

  return ComboMigrationPlan(
    defaultId: keep.profile.id,
    rewrites: rewrites,
    report: report,
    srs: srsDecision,
  );
}

const SettingKey _srsLibraryKey = SettingKey(
  kComboSyntheticCategory,
  kComboSrsLibrarySettingKey,
);

ComboDocument _withOwnLibrary(ComboDocument doc) =>
    ComboDocument(<String, Map<SettingKey, String>>{
      ...doc.splits,
      kComboSrsLibraryLeafId: <SettingKey, String>{
        _srsLibraryKey: kComboSrsLibraryOwnValue,
      },
    });

List<String> _inTreeOrder(SettingsTree tree, Set<String> leafIds) => <String>[
  for (final SettingsNode leaf in tree.leaves)
    if (leafIds.contains(leaf.id)) leaf.id,
];

/// 语言与媒体类型都绑了、且两边不是同一份时，迁移前（语言高于媒体类型、整包切换）与迁移后
/// （媒体类型高于语言、逐叶子）的生效值哪些叶子不同。迁移前 = 整包取语言那份 = 语言层单独
/// 解析；迁移后 = 两层一起解析。
List<ComboBindingConflict> _conflicts({
  required SettingsTree tree,
  required Map<SettingKey, String> base,
  required int keepId,
  required Map<int, ComboDocument> documents,
  required Map<int, String> names,
  required ComboMigrationBindings bindings,
}) {
  ComboDocument docOf(int id) =>
      id == keepId ? ComboDocument.empty : documents[id] ?? ComboDocument.empty;
  final List<ComboBindingConflict> out = <ComboBindingConflict>[];
  final List<String> languages = bindings.language.keys.toList()..sort();
  final List<String> mediaTypes = bindings.mediaType.keys.toList()..sort();
  for (final String language in languages) {
    final int langId = bindings.language[language]!;
    if (!names.containsKey(langId)) continue;
    final ResolvedSettings before = resolveCombos(
      tree: tree,
      defaults: base,
      layers: <ComboLayer>[
        ComboLayer(
          scope: ComboScope.language,
          comboRef: '$langId',
          document: docOf(langId),
        ),
      ],
    );
    for (final String mediaType in mediaTypes) {
      final int mediaId = bindings.mediaType[mediaType]!;
      if (mediaId == langId || !names.containsKey(mediaId)) continue;
      final ResolvedSettings after = resolveCombos(
        tree: tree,
        defaults: base,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.mediaType,
            comboRef: '$mediaId',
            document: docOf(mediaId),
          ),
          ComboLayer(
            scope: ComboScope.language,
            comboRef: '$langId',
            document: docOf(langId),
          ),
        ],
      );
      final List<String> changed = <String>[
        for (final SettingsNode leaf in tree.leaves)
          if (!_sameMap(
            before.leafValues(tree, leaf.id),
            after.leafValues(tree, leaf.id),
          ))
            leaf.id,
      ];
      if (changed.isEmpty) continue;
      out.add(
        ComboBindingConflict(
          languageTag: language,
          mediaType: mediaType,
          languageProfile: names[langId]!,
          mediaTypeProfile: names[mediaId]!,
          leaves: changed,
        ),
      );
    }
  }
  return out;
}

List<ComboIgnoredSplitEntry> _ignoredSplits({
  required SettingsTree tree,
  required int keepId,
  required Map<int, ComboDocument> documents,
  required Map<int, String> names,
  required ComboMigrationBindings bindings,
}) {
  final List<ComboIgnoredSplitEntry> out = <ComboIgnoredSplitEntry>[];
  final Map<ComboScope, Map<String, int>> byScope =
      <ComboScope, Map<String, int>>{
        ComboScope.work: bindings.work,
        ComboScope.mediaType: bindings.mediaType,
        ComboScope.language: bindings.language,
      };
  for (final ComboScope scope in ComboScope.bindingLayers) {
    final Map<int, int> counts = <int, int>{};
    for (final int id in byScope[scope]!.values) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    final List<int> ids = counts.keys.toList()..sort();
    for (final int id in ids) {
      if (id == keepId) continue;
      final ComboDocument? doc = documents[id];
      if (doc == null) continue;
      final List<String> leaves = <String>[
        for (final SettingsNode leaf in tree.leaves)
          if (doc.isSplit(leaf.id) && !leaf.splittableAt.contains(scope))
            leaf.id,
      ];
      if (leaves.isEmpty) continue;
      out.add(
        ComboIgnoredSplitEntry(
          profile: names[id]!,
          scope: scope,
          bindings: counts[id]!,
          leaves: leaves,
        ),
      );
    }
  }
  return out;
}

bool _sameMap(Map<SettingKey, String> a, Map<SettingKey, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<SettingKey, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}
