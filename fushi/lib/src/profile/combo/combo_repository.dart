/// 「组合」的仓库层（拍板台 design-combo-node-split，阶段 2）：读写 `profile_settings` 里的
/// 组合行、按绑定层组装并解析生效值。
///
/// * 解析的底 = 激活配置（`active_profile_id`）此刻的生效值，即 live 表（偏好 / Anki / 词典
///   元数据），由 [ComboRepository.new] 的 `liveSettings` 现读。阶段 3 迁移后持久化的默认组合是
///   `combo/role = default` 那一份（[ComboRepository.defaultComboId]）；激活配置是别的组合时，
///   live = 默认组合 + 它的拆分（`ProfileRepository.applyProfile`），绑定层照样以 live 为底。
/// * 其他 Profile 有两种行格式（[decodeComboRows]）：
///   - 组合格式（有 `combo/role` 行）：只存被拆叶子，按行解码；
///   - 存量整份快照（阶段 3 迁移前的全部 Profile；默认组合不是激活配置时同样是全量）：**读时**按
///     [diffAgainstDefaults] 化成相对默认组合的差异。单层时与旧版「整包取这份快照」的生效值
///     逐键一致（与默认相同的叶子取默认 = 同一个值；不同的叶子取快照），多层时每个叶子各自
///     往下找，媒体类型 / 语言层不再整包切换。阶段 3 把这份差异一次性落库后就不再走这条。
/// * 写入一律经 [ComboRepository.writeSettings]：组合格式走 [writeSetting]（自动拆叶子）并整份
///   落库；存量快照按旧语义改那一行（单层时与组合语义等价：叶子与默认相同时快照里那组键就是
///   默认值，改一个键 = 拆出该叶子再改）。
///
/// 设计见 `docs/specs/2026-11-23-combo-settings-tree-design.md` §3。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';

export 'package:fushi_engine/profile/combo/combo_migration.dart';
export 'package:fushi_engine/profile/combo/combo_resolver.dart';
export 'package:fushi_engine/profile/combo/combo_rows.dart';
export 'package:fushi_engine/profile/combo/settings_tree.dart';
export 'package:fushi_engine/profile/combo/combo_srs_library.dart';

/// 读激活配置（默认组合）此刻的全量设置；[categories] 非 null 时只读这些 category。
typedef ComboLiveSettingsReader =
    Future<Map<SettingKey, String>> Function({Set<String>? categories});

/// 一次按绑定层解析的结果。
class ResolvedComboStack {
  ResolvedComboStack({
    required this.defaultProfileId,
    required Map<ComboScope, int> layers,
    required Map<String, int> profileIdByRef,
    required this.settings,
  }) : layers = Map<ComboScope, int>.unmodifiable(layers),
       profileIdByRef = Map<String, int>.unmodifiable(profileIdByRef);

  /// 默认组合（激活配置）id。
  final int defaultProfileId;

  /// 实际参与解析的绑定层（已去掉指向默认组合、已不存在的 Profile），层 → Profile id。
  final Map<ComboScope, int> layers;

  /// [ComboLayer.comboRef]（`profiles.uid`）→ Profile id。
  final Map<String, int> profileIdByRef;

  final ResolvedSettings settings;

  /// 叶子 [leafId] 的来源 Profile；null = 默认组合。
  int? sourceProfileIdOf(String leafId) {
    final String? ref = settings.sourceOf(leafId).comboRef;
    return ref == null ? null : profileIdByRef[ref];
  }

  /// 优先级最高的绑定层的 Profile；没有绑定层时 null。
  int? get topProfileId {
    for (final ComboScope s in ComboScope.bindingLayers) {
      final int? id = layers[s];
      if (id != null) return id;
    }
    return null;
  }
}

class ComboRepository {
  ComboRepository(
    this._db, {
    required ComboLiveSettingsReader liveSettings,
    required Future<int> Function() activeProfileId,
    SettingsTree? tree,
  }) : _liveSettings = liveSettings,
       _activeProfileId = activeProfileId,
       tree = tree ?? fushiSettingsTree;

  final FushiDatabase _db;
  final ComboLiveSettingsReader _liveSettings;
  final Future<int> Function() _activeProfileId;
  final SettingsTree tree;

  /// [profileId] 的全部 `profile_settings` 行（只按 [categories] 过滤，null = 全部）。
  /// 存量快照里的旧 category（`dictionary` / `reader`）换成今天落到的 pref 键；与新式行
  /// 撞键时新式行优先（与 `applyProfile` 的旧 category 分支同一映射）。
  Future<Map<SettingKey, String>> rowsOf(
    int profileId, {
    Set<String>? categories,
  }) async {
    final Map<SettingKey, String> modern = <SettingKey, String>{};
    final Map<SettingKey, String> legacy = <SettingKey, String>{};
    for (final ProfileSettingRow row in await _db.getProfileSettings(
      profileId,
    )) {
      final SettingKey raw = SettingKey(row.category, row.key);
      final SettingKey k = normalizeLegacySettingKey(raw);
      if (categories != null &&
          !categories.contains(k.category) &&
          k.category != kComboSyntheticCategory) {
        continue;
      }
      (identical(k, raw) ? modern : legacy)[k] = row.value;
    }
    return <SettingKey, String>{...legacy, ...modern};
  }

  /// 默认组合（有 `combo/role = default` 行的那份）的 id；还没迁移成组合格式（全是存量整份
  /// 快照）时 null。坏状态下有多份时取 id 最小的（下一次归一会把其余降级）。
  Future<int?> defaultComboId() async {
    int? found;
    for (final MapEntry<int, String> e in (await _db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboRoleKey,
    )).entries) {
      if (e.value != ComboRole.defaults.wire) continue;
      if (found == null || e.key < found) found = e.key;
    }
    return found;
  }

  /// [profileId] 的行是否已是组合格式。
  Future<bool> isComboFormat(int profileId) async =>
      decodeComboRows(tree, await rowsOf(profileId)).isComboFormat;

  /// [profileId] 相对默认组合 [defaults] 的差异文档。组合格式按行解码；存量快照读时 diff
  /// （见库文档）。
  Future<ComboDocument> documentOf(
    int profileId, {
    required Map<SettingKey, String> defaults,
    Set<String>? categories,
  }) async {
    final DecodedComboRows decoded = decodeComboRows(
      tree,
      await rowsOf(profileId, categories: categories),
    );
    if (isSplitDocument(decoded)) return decoded.document;
    // 存量快照，或已不是激活配置的默认组合（全量值）：读时 diff。
    return diffAgainstDefaults(
      tree: tree,
      defaults: defaults,
      snapshot: decoded.values,
    );
  }

  /// 按绑定层 [layers]（层 → Profile id）解析生效值。指向默认组合（激活配置）的层直接丢掉
  /// ——默认组合本来就在最底层；已不存在的 Profile 也丢掉。[categories] 非 null 时只解析
  /// 这些 category 的键（制卡链现读 Anki 字段用，省掉词典元数据）：调用方要保证关心的叶子
  /// 的键全在其中。
  Future<ResolvedComboStack> resolve(
    Map<ComboScope, int> layers, {
    Set<String>? categories,
  }) async {
    final int defaultId = await _activeProfileId();
    final Map<SettingKey, String> defaults = await _liveSettings(
      categories: categories,
    );
    final Map<ComboScope, int> used = <ComboScope, int>{};
    final Map<String, int> idByRef = <String, int>{};
    final List<ComboLayer> comboLayers = <ComboLayer>[];
    for (final ComboScope scope in ComboScope.bindingLayers) {
      final int? id = layers[scope];
      if (id == null || id <= 0 || id == defaultId) continue;
      if (await _db.getProfileById(id) == null) continue;
      final String ref = await _db.profileUidOf(id);
      used[scope] = id;
      idByRef[ref] = id;
      comboLayers.add(
        ComboLayer(
          scope: scope,
          comboRef: ref,
          document: await documentOf(
            id,
            defaults: defaults,
            categories: categories,
          ),
        ),
      );
    }
    return ResolvedComboStack(
      defaultProfileId: defaultId,
      layers: used,
      profileIdByRef: idByRef,
      settings: resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: comboLayers,
      ),
    );
  }

  /// 把非默认组合 [profileId] 整份写成组合格式（[document] 的被拆叶子 + 标记行），事务内
  /// 全量替换。阶段 3 迁移与阶段 6 编辑页的落库口。
  Future<void> saveDocument(
    int profileId,
    ComboDocument document, {
    ComboRole role = ComboRole.named,
  }) async {
    final Map<SettingKey, String> rows = encodeComboRows(
      tree,
      document,
      role: role,
    );
    await _db.replaceProfileSettings(profileId, <ProfileSettingsCompanion>[
      for (final MapEntry<SettingKey, String> e in rows.entries)
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: e.key.category,
          key: e.key.key,
          value: e.value,
        ),
    ]);
  }

  /// 在非默认组合 [profileId]（挂在 [scope] 层）上写一批设置（值为 null = 在这一层设为
  /// 「未设置」）。组合格式：所属叶子还在继承时先按默认组合的当前值拆出来（[writeSetting]），
  /// 再整份落库；存量快照：按旧语义改那几行。
  ///
  /// 调用方保证 [profileId] 不是默认组合（激活配置的真值在 live 表，直接写 live）。
  /// [scope] 只用来校验叶子允许在这一层拆：作品层是最严的一层（作品层可拆的叶子在其余层
  /// 都可拆），不知道挂在哪层时传 [ComboScope.work]。
  Future<void> writeSettings(
    int profileId,
    Map<SettingKey, String?> changes, {
    ComboScope scope = ComboScope.work,
  }) async {
    if (changes.isEmpty) return;
    // 默认组合的当前值在事务外读：live 设置的读取方（Anki 设置存储）不一定走这个库的事务。
    // 只有组合格式的自动拆分要用它。
    final ResolvedSettings? effective =
        isSplitDocument(decodeComboRows(tree, await rowsOf(profileId)))
        ? resolveCombos(tree: tree, defaults: await _liveSettings())
        : null;
    await _db.transaction(() async {
      final DecodedComboRows decoded = decodeComboRows(
        tree,
        await rowsOf(profileId),
      );
      if (!isSplitDocument(decoded)) {
        for (final MapEntry<SettingKey, String?> e in changes.entries) {
          final String? value = e.value;
          if (value == null) {
            await _db.deleteProfileSetting(
              profileId,
              e.key.category,
              e.key.key,
            );
          } else {
            await _db.upsertProfileSetting(
              ProfileSettingsCompanion.insert(
                profileId: profileId,
                category: e.key.category,
                key: e.key.key,
                value: value,
              ),
            );
          }
        }
        return;
      }
      final ResolvedSettings base =
          effective ??
          resolveCombos(tree: tree, defaults: await _liveSettings());
      ComboDocument document = decoded.document;
      for (final MapEntry<SettingKey, String?> e in changes.entries) {
        document = writeSetting(
          tree: tree,
          document: document,
          scope: scope,
          key: e.key,
          value: e.value,
          effective: base,
        );
      }
      await saveDocument(profileId, document, role: decoded.role!);
    });
  }

  /// 行是「只存被拆叶子」的差异文档（非默认角色的组合格式）。存量快照与默认组合存全量值，
  /// 改行即可。
  static bool isSplitDocument(DecodedComboRows decoded) =>
      decoded.isComboFormat && decoded.role != ComboRole.defaults;
}
