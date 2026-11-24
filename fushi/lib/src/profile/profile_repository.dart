import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdateQuery, Value;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show kDictKanjiPartSettingKeys, kanjiPartSettingsIn;
import 'package:fushi_engine/profile/profile_document.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show dbSourcePrefKey, kReaderSourcePersistedKey;
import 'package:fushi/src/models/preference_keys.dart'
    show
        kMiningTtsFallbackVoicePref,
        kMiningTtsFallbackVoiceProfilePrefKeyPrefix,
        kComboMigrationNoticePendingPrefKey,
        kComboMigrationReportPrefKey,
        kProfileFallbackIdPrefKey;
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart'
    show FushiComboNode, normalizeLegacySettingKey;
import 'package:fushi/src/profile/combo/srs_library_resolver.dart';
import 'package:fushi/src/profile/language_binding.dart';
import 'package:fushi/src/profile/profile_deletion_cascade.dart'
    show ProfileHostsSharedSrsLibraryException;
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi/src/profile/remote_dictionary_profile_meta.dart';
import 'package:fushi/src/sync/backup_path_rebase.dart'
    show rebaseFontCatalogJson, rebaseFontListJson;
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart'
    show
        SyncRepository,
        isRemoteDictionaryPseudoHostId,
        remoteDictionaryLookupHostIdsOf;
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart'
    show kPageBackdropProfileParkedPrefKeyPrefixes;

// 分享 JSON 的模型与异常已下沉引擎（服务端共用），这里转出，调用方 import 不变。
export 'package:fushi_engine/profile/profile_document.dart'
    show ProfileExport, ProfileImportException, ProfileSettingEntry;
// 服务器词典快照 key 的编解码搬到了独立文件（目录对账也要用，BUG-4693），这里转出。
export 'package:fushi/src/profile/remote_dictionary_profile_meta.dart'
    show remoteDictionaryProfileKey, remoteDictionaryHostIdOfProfileKey;

/// 导入模式：新建一个 Profile（默认，重名加后缀），或覆盖一个已有 Profile。
enum ProfileImportMode { createNew, overwrite }

/// 复习库里哪些 Profile uid 有用户数据（组合迁移 §4.2 的判据）；返回 null = 复习库此刻读不了
/// （换代中 / 打不开），复习库结论留到下次。
typedef ComboSrsUserDataProbe =
    Future<Set<String>?> Function(List<String> uids);

class ProfileRepository {
  ProfileRepository(
    this._db,
    this._ankiRepo, {
    bool Function(String name)? isDictionaryInstalled,
    ComboSrsUserDataProbe? srsUserData,
    Future<Directory> Function()? comboMigrationBackupDirectory,
  }) : _isDictionaryInstalled = isDictionaryInstalled,
       _srsUserData = srsUserData,
       _comboMigrationBackupDirectory = comboMigrationBackupDirectory;
  final FushiDatabase _db;
  final BaseAnkiRepository _ankiRepo;

  /// 组合迁移定复习库归属用（§4.2）；null = 这个仓储实例不定（只有一份 Profile 时不需要它）。
  final ComboSrsUserDataProbe? _srsUserData;

  /// 组合迁移前把原快照整份写进这里（撤销途径）；null = 不写备份文件（测试 / 只读用途的实例）。
  final Future<Directory> Function()? _comboMigrationBackupDirectory;

  /// 组合仓库（拍板台 design-combo-node-split 阶段 2）：默认组合 = 激活配置，live 值由
  /// [currentSettings] 现读。
  late final ComboRepository combos = ComboRepository(
    _db,
    liveSettings: currentSettings,
    activeProfileId: getActiveProfileId,
  );

  /// 「这本词典**真的装着**吗」的唯一真值源：磁盘上有没有
  /// `dictionaryResourceDirectory/<name>/`。元数据行的存在性**不是**这个判据——
  /// BUG-1994 的旧 prune 恰恰会把已安装词典的行删掉。
  ///
  /// 可空：不注入时 [applyProfile] 一律不回插（等于「无法证明装着」）。测试与
  /// 不关心词典的调用方保持零依赖。
  final bool Function(String name)? _isDictionaryInstalled;

  Future<List<ProfileRow>> getAllProfiles() => _db.getAllProfiles();

  /// BUG-3148：`profiles` 表的任何写入（新建 / 改名 / 删除 / 导入）都会在这里冒一个
  /// 事件，不论写入方是谁。
  ///
  /// 配置列表的视图模型是常驻的（非 autoDispose），以前只在自己发起的操作之后重读；
  /// 互联「下载配置」与对端「上传配置」入站这两条写入绕过了它，列表就一直停在旧值，
  /// 杀后台重进才看得到新配置。表级变更流是 drift 自带的唯一真相，比在每个写入点
  /// 记得通知一遍可靠。
  Stream<void> watchProfilesChanged() =>
      _db.tableUpdates(TableUpdateQuery.onTable(_db.profiles)).map((_) {});

  Future<ProfileRow?> getProfileById(int id) => _db.getProfileById(id);

  Future<int> getActiveProfileId() async {
    final raw = await _db.getPref('active_profile_id');
    return raw != null ? (int.tryParse(raw) ?? -1) : -1;
  }

  Future<void> setActiveProfileId(int id) =>
      _db.setPref('active_profile_id', id.toString());

  /// 「绑定切换前」用户自己选的那份配置（见 [kProfileFallbackIdPrefKey]）。
  /// null = 当前激活配置就是用户自己选的，没有处于「绑定临时生效」状态。
  Future<int?> getFallbackProfileId() async {
    final raw = await _db.getPref(kProfileFallbackIdPrefKey);
    return raw == null ? null : int.tryParse(raw);
  }

  Future<void> setFallbackProfileId(int? id) => id == null
      ? _db.deletePref(kProfileFallbackIdPrefKey)
      : _db.setPref(kProfileFallbackIdPrefKey, id.toString());

  /// 新建一份 Profile。已迁移成组合格式的库里它是什么都没拆的普通组合（全部继承默认组合；
  /// 调用方随后的 [snapshotCurrentSettings] 会把此刻生效值与默认组合不同的叶子拆进来）。
  Future<int> createProfile(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final bool comboWorld = await combos.defaultComboId() != null;
    final id = await _db.insertProfile(
      ProfilesCompanion.insert(name: name, createdAt: now, updatedAt: now),
    );
    if (comboWorld) {
      await combos.saveDocument(id, ComboDocument.empty);
    }
    return id;
  }

  Future<void> renameProfile(int id, String name) =>
      _db.updateProfileName(id, name);

  /// [id] 承载着共享复习库（删了所有没拆独立库的组合的复习就没了，见
  /// [ProfileHostsSharedSrsLibraryException]）。共享库还没定时 false（迁移待定：照旧按配置删）。
  Future<bool> hostsSharedSrsLibrary(int id) async =>
      (await loadComboSrsLibraries(_db)).hostsSharedLibrary(id);

  /// 删一份 Profile。承载共享复习库的那份不删，抛 [ProfileHostsSharedSrsLibraryException]。
  Future<void> deleteProfile(int id) async {
    final count = await _db.countProfiles();
    if (count <= 1) return;
    if (await hostsSharedSrsLibrary(id)) {
      throw ProfileHostsSharedSrsLibraryException(id);
    }

    final activeId = await getActiveProfileId();
    final String? deletedUid = await _profileUidOrNull(id);
    // 删的是默认组合：先把接班的那份提升成默认、其余组合改基到它（生效值不变），再删。
    // 接班 = 激活配置（它不是被删的那份时），否则最早建的另一份。
    int? successor;
    if (id == await combos.defaultComboId()) {
      if (activeId != id && await _db.getProfileById(activeId) != null) {
        successor = activeId;
      } else {
        for (final ProfileRow p in await _db.getAllProfiles()) {
          if (p.id != id) {
            successor = p.id;
            break;
          }
        }
      }
      if (successor != null) {
        await _promoteToDefault(successor, previousDefaultId: id);
      }
    }
    await _db.deleteProfile(id);
    if (deletedUid != null) {
      for (final String prefix in perProfileDeviceLocalPrefs.values) {
        await _db.deletePref('$prefix$deletedUid');
      }
    }

    if (activeId == id) {
      final remaining = await _db.getAllProfiles();
      if (remaining.isNotEmpty) {
        final int next = successor ?? remaining.first.id;
        await setActiveProfileId(next);
        await applyProfile(next);
      }
    }
  }

  Future<void> snapshotCurrentSettings(int profileId) async {
    // Profile ids are autoincrement (always >= 1); a non-positive id is the
    // "no active profile" sentinel (e.g. ProfileViewModel.dispose fires before
    // _load assigns a real id, so state.activeProfileId is still -1).
    // Snapshotting it would write orphan profile_settings rows / trip the FK.
    if (profileId <= 0) return;

    await _parkPerProfileDeviceLocalPrefs(profileId);

    final Map<SettingKey, String> current = await currentSettings();
    final Map<SettingKey, String> rows = await combos.rowsOf(profileId);
    final DecodedComboRows decoded = decodeComboRows(combos.tree, rows);
    if (ComboRepository.isSplitDocument(decoded)) {
      // 组合格式（只存被拆叶子）：活偏好 = 默认组合 + 它的拆分，写回时只记相对默认组合不同的
      // 叶子（原来拆了的保持拆分）——绝不能把差异文档覆盖成全量快照。
      final int? defaultId = await combos.defaultComboId();
      if (defaultId != null && defaultId != profileId) {
        await combos.saveDocument(
          profileId,
          rebaseComboDocument(
            tree: combos.tree,
            existing: decoded.document,
            base: await _defaultComboValues(defaultId),
            effective: current,
          ),
          role: decoded.role!,
        );
        return;
      }
    }
    // 全量快照（默认组合 / 存量快照）：组合格式元数据行（`role` / `srs_shared_uid`）原样留着。
    await _db.replaceProfileSettings(profileId, <ProfileSettingsCompanion>[
      for (final MapEntry<SettingKey, String> e in <SettingKey, String>{
        ...current,
        for (final MapEntry<SettingKey, String> r in rows.entries)
          if (r.key.category == kComboSyntheticCategory) r.key: r.value,
      }.entries)
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: e.key.category,
          key: e.key.key,
          value: e.value,
        ),
    ]);
  }

  /// 激活配置（默认组合）此刻的全量设置，即 [snapshotCurrentSettings] 写进快照的那一份；
  /// [categories] 非 null 时只读这些 category（[ComboRepository.resolve] 只关心制卡字段时用）。
  Future<Map<SettingKey, String>> currentSettings({
    Set<String>? categories,
  }) async {
    bool wants(String category) =>
        categories == null || categories.contains(category);
    final Map<SettingKey, String> out = <SettingKey, String>{};

    // Anki settings (Drift `anki_settings` row via the repository store)
    if (wants(ProfileKeys.categoryAnki)) {
      final ankiSettings = await _ankiRepo.loadSettings();
      for (final entry in ProfileKeys.ankiSettingsToMap(ankiSettings).entries) {
        out[SettingKey(ProfileKeys.categoryAnki, entry.key)] = entry.value;
      }
    }

    // ALL Drift prefs (excluding app-state keys)
    if (wants(ProfileKeys.categoryPref)) {
      for (final entry in (await _db.getAllPrefs()).entries) {
        if (ProfileKeys.isExcludedPref(entry.key)) continue;
        out[SettingKey(ProfileKeys.categoryPref, entry.key)] = entry.value;
      }
    }

    // TODO-1077: dictionary enable-list / order / source / language visibility
    // live in the standalone `dictionary_metadata` table, not in prefs, so they
    // were previously shared across all profiles. Snapshot one row per
    // dictionary (key = dictionary name) into the dedicated
    // [ProfileKeys.categoryDictionaryMeta] category so they follow the profile.
    if (wants(ProfileKeys.categoryDictionaryMeta)) {
      for (final DictionaryMetaRow row
          in await _db.getAllDictionaryMetadata()) {
        out[SettingKey(ProfileKeys.categoryDictionaryMeta, row.name)] =
            _encodeDictionaryMeta(row);
      }
    }

    // v153：服务器托管词典的顺序 / 开关同理属于配置。目录行本身（host 上有哪些）是
    // 全局事实，只快照配置拥有的两列；暂时没参与查词的 host（关掉 / 未连上）的行也
    // 快照，否则切回来时它们的设置就丢了。
    if (wants(ProfileKeys.categoryRemoteDictionaryMeta)) {
      for (final RemoteDictionaryMetaRow row
          in await _db.getAllRemoteDictionaryMetadata()) {
        out[SettingKey(
          ProfileKeys.categoryRemoteDictionaryMeta,
          remoteDictionaryProfileKey(row.hostId, row.name),
        )] = jsonEncode(<String, Object>{
          'order': row.order,
          'hidden': row.hidden,
        });
      }
    }
    return out;
  }

  Future<void> applyProfile(int profileId) async {
    // A non-positive (sentinel) id has no snapshot rows, so the prune step
    // below would delete EVERY non-excluded live pref — silent settings wipe.
    // Ids are always >= 1, so guard the sentinel instead of nuking prefs.
    if (profileId <= 0) return;

    // 组合格式（只存被拆叶子）：应用的是它在默认组合之上的生效值，不是它那几行——否则下面的
    // prune 会删掉所有没拆的设置。全量快照（默认组合 / 存量快照）照旧整份应用。
    final DecodedComboRows decoded = decodeComboRows(
      combos.tree,
      await combos.rowsOf(profileId),
    );
    final _DecodedProfileSnapshot snapshot =
        ComboRepository.isSplitDocument(decoded)
        ? _decodeSettings(
            await _effectiveOverDefault(profileId, decoded.document),
          )
        : _decodeSnapshot(await _db.getProfileSettings(profileId));
    final Map<String, String> ankiMap = snapshot.ankiMap;
    final Map<String, String> prefMap = snapshot.prefMap;
    final Map<String, DictionaryMetadataCompanion> dictMetaMap =
        snapshot.dictMetaMap;
    final bool hasDictMeta = snapshot.hasDictMeta;
    final Map<String, RemoteDictionaryProfileColumns> remoteDictMetaMap =
        snapshot.remoteDictMetaMap;

    // Wrap DB writes in transaction for consistency
    await _db.transaction(() async {
      final currentPrefs = await _db.getAllPrefs();
      for (final key in currentPrefs.keys) {
        if (ProfileKeys.isExcludedPref(key)) continue;
        if (!prefMap.containsKey(key)) {
          await _db.deletePref(key);
        }
      }
      // BUG-1994: profile 只拥有「怎么排、开不开」，**不拥有「装了哪些」**。
      //
      // TODO-1077 原来的做法是「快照即真相」：upsert 快照里的每一行，再删掉快照
      // 没有的 live 行（照抄上面 pref 的 prune）。那等于把「这本词典启用中」编码
      // 成「元数据行存在」，可这一行同时还承载「这本词典已安装」这个**全局**事实
      // ——两个正交语义挤进同一个存在性判据。后果是在 A 里导入的词典，切到更早
      // 建的 B 时被当成「B 没启用它」而整行删掉，B 的词典库里直接消失（明镜/牛津
      // 只差一个「在 B 建立之前还是之后导入」）。开关和顺序本来就是行内的列
      // （hiddenLanguagesJson / order），行的存在性根本不该再兼任开关。
      //
      // 所以：不再 prune，只把 profile 拥有的四列写回**已存在**的行。
      //
      // 更新命中 0 行 = 快照有这个名字、库里没有这一行。这里有两种真实成因，靠
      // 「磁盘上有没有 `dictionaryResourceDirectory/<name>/`」区分——**元数据行在
      // 不在**从来就不是「装没装」的判据（那正是本 bug 的病根）：
      //   * 目录不存在 → 词典真的被删了，快照比库旧。跳过，绝不 insert（插进去
      //     就是一行没有磁盘目录的幽灵元数据）。
      //   * 目录还在   → 这一行是被旧版本的 prune 删掉的**真行**，词典还躺在磁盘
      //     上。按快照整行补回来。旧实现里这条自愈是 `upsertDictionaryMeta` 顺带
      //     给的（用户报告 T5「切回 A 牛津又出现」），一并砍掉会把「切回去就有」
      //     变成「永远没有」——升级时正停在受害 profile 的用户直接永久丢失。
      //     never break userspace：自愈保留，只是判据从「快照即真相」换成磁盘。
      // `hasDictMeta` 保留：前 TODO-1077 的旧快照没有 dictionary_meta 行，跳过整
      // 段即可，不能被误当成「没有词典」。
      if (hasDictMeta) {
        final Map<String, DictionaryMetaRow> liveDictRows =
            <String, DictionaryMetaRow>{
              for (final DictionaryMetaRow r
                  in await _db.getAllDictionaryMetadata())
                r.name: r,
            };
        for (final MapEntry<String, DictionaryMetadataCompanion> entry
            in dictMetaMap.entries) {
          final DictionaryMetadataCompanion companion = entry.value;
          final int updated = await _db.applyDictionaryMetaProfileColumns(
            name: entry.key,
            order: companion.order.value,
            hiddenLanguagesJson: companion.hiddenLanguagesJson.value,
            collapsedLanguagesJson: companion.collapsedLanguagesJson.value,
            expandedLanguagesJson: companion.expandedLanguagesJson.value,
            languageOverride: companion.languageOverride.value,
            metadataJson: _metadataWithProfileKanjiPartSettings(
              liveDictRows[entry.key]?.metadataJson,
              companion.metadataJson.value,
            ),
          );
          if (updated == 0 &&
              (_isDictionaryInstalled?.call(entry.key) ?? false)) {
            await _db.upsertDictionaryMeta(companion);
          }
        }
      }
      // v153：服务器托管词典只写回**已有**目录行的顺序 / 开关。命中 0 行 = 本机目录
      // 里没有这本（host 换了 / 配置来自别的设备 / 目录还没拉过）：跳过，绝不插行——
      // 目录只由刷新建立，快照不知道 host 上有什么。这本之后在刷新里第一次出现时，
      // 对账插行会先读激活配置的这份快照（BUG-4693，见
      // `RemoteDictionaryCatalogService.reconcileHost`），所以配置的选择不必等到下一次
      // 切换才生效；之后再应用同一配置写的是同一对值，不会互相打架。快照里没有的
      // 目录行保持 live 值（与本机词典同口径）。
      for (final RemoteDictionaryProfileColumns columns
          in remoteDictMetaMap.values) {
        await _db.setRemoteDictionaryProfileColumns(
          hostId: columns.hostId,
          name: columns.name,
          order: columns.order,
          hidden: columns.hidden,
        );
      }
      await _restorePerProfileDeviceLocalPrefs(profileId);
      for (final entry in prefMap.entries) {
        // [FushiDatabase.setPref] auto-bumps the persisted prefs-version
        // (TODO-855) for every non-version key written here, so the common
        // profile switch (which always writes at least one pref) is already
        // signalled to the :popup process.
        await _db.setPref(entry.key, entry.value);
      }
      // TODO-855: guarantee a bump even for the edge cases the per-key
      // auto-bump above does NOT cover — a switch into a profile with an empty
      // snapshot, or one whose only effect is deleting prefs (deletePref does
      // not bump). Read the CURRENT (post-loop, already-bumped) version and add
      // one more so the counter is always present and strictly monotonic; an
      // extra increment on top of the per-key bumps is harmless (the popup just
      // reloads once on its next lookup). Written through _db.setPref against
      // the version key itself, whose recursion guard skips re-bumping, so this
      // does NOT double-count. prefs_version is excluded from profile snapshots,
      // so it is neither pruned above nor present in prefMap.
      final String? rawVersion = await _db.getPref(
        PreferencesRepository.prefsVersionKey,
      );
      final int nextVersion =
          (rawVersion == null ? 0 : PrefCodec.decode<int>(rawVersion, 0)) + 1;
      await _db.setPref(
        PreferencesRepository.prefsVersionKey,
        PrefCodec.encode(nextVersion),
      );
    });

    // Anki settings (Drift `anki_settings` row via the repository store)
    if (ankiMap.isNotEmpty) {
      final current = await _ankiRepo.loadSettings();
      final updated = ProfileKeys.mapToAnkiSettings(ankiMap, current);
      await _ankiRepo.saveSettings(updated);
    }
  }

  /// 复制一份 Profile。组合格式的库里副本是普通组合：源是组合 → 同样的拆分；源是默认组合 →
  /// 什么都不拆（全部继承默认，即此刻与源相同）；源是残留的存量快照 → 相对默认组合的差异。
  /// 默认组合只能有一份，副本绝不带走 `role = default`。
  Future<int> copyProfile(int sourceId, String newName) async {
    final int? defaultId = await combos.defaultComboId();
    final newId = await createProfile(newName);
    if (defaultId == null) {
      final sourceSettings = await _db.getProfileSettings(sourceId);
      final copies = sourceSettings
          .map(
            (s) => ProfileSettingsCompanion.insert(
              profileId: newId,
              category: s.category,
              key: s.key,
              value: s.value,
            ),
          )
          .toList();
      await _db.replaceProfileSettings(newId, copies);
    } else {
      final DecodedComboRows decoded = decodeComboRows(
        combos.tree,
        await combos.rowsOf(sourceId),
      );
      await combos.saveDocument(
        newId,
        ComboRepository.isSplitDocument(decoded)
            ? decoded.document
            : sourceId == defaultId
            ? ComboDocument.empty
            : diffAgainstDefaults(
                tree: combos.tree,
                defaults: await _defaultComboValues(defaultId),
                snapshot: decoded.values,
              ),
      );
    }
    // 设备本地的按配置键不在快照里，单独跟着复制：副本一开始与源配置用同一个声音。
    final String? sourceUid = await _profileUidOrNull(sourceId);
    if (sourceUid != null) {
      final String newUid = await _db.profileUidOf(newId);
      for (final String prefix in perProfileDeviceLocalPrefs.values) {
        final String? parked = await _db.getPref('$prefix$sourceUid');
        if (parked != null) await _db.setPref('$prefix$newUid', parked);
      }
    }
    return newId;
  }

  /// 按配置记、但只留在本机的偏好（拍板台 olNAZUnEy6，方案 A）：live 键 → 停放键前缀（后缀 = profile uid）。
  ///
  /// live 键本身是设备本地的（[ProfileKeys.isExcludedPref]），不进快照、切配置时也不被剪掉；全部读取方只读
  /// live 键，代表**当前激活配置**的选择。各配置自己的值停放在「前缀 + uid」下：
  /// * 切走（[snapshotCurrentSettings]）时把 live 值停放到这份配置名下（没写过 = 空串，「没选过」）；
  /// * 切入（[applyProfile]）时把停放值换回 live 键；没停放过的配置（升级前建的 / 新建的）不动 live 值，
  ///   即沿用切换前的选择——现有全局值就是每个配置的初始值，不需要一次性迁移；
  /// * 非激活配置的只读视图（[loadSettingsView]：浏览器扩展 / 互联选了别的配置）取停放值。
  ///
  /// 页面背景图片同理（[kPageBackdropProfileParkedPrefKeyPrefixes]）：文件只在本机，换配置要换图。
  ///
  /// 兜底声音的值多半指向本机朗读声音预设（`tts_voice_presets` 设备本地），带到别的设备只会指向不存在的
  /// 预设，所以不走快照 / 导出 / 同步，只在本机按配置记。
  static const Map<String, String>
  perProfileDeviceLocalPrefs = <String, String>{
    kMiningTtsFallbackVoicePref: kMiningTtsFallbackVoiceProfilePrefKeyPrefix,
    // 页面背景图片（与取色缓存）：样式随快照走，图片文件只在本机，按配置停放。
    ...kPageBackdropProfileParkedPrefKeyPrefixes,
  };

  /// 配置的 uid；配置行已不存在时 null。
  Future<String?> _profileUidOrNull(int profileId) async {
    if (profileId <= 0) return null;
    if (await _db.getProfileById(profileId) == null) return null;
    return _db.profileUidOf(profileId);
  }

  /// 把 [perProfileDeviceLocalPrefs] 的 live 值停放到 [profileId] 名下（live 没有 = 空串）。
  Future<void> _parkPerProfileDeviceLocalPrefs(int profileId) async {
    final String? uid = await _profileUidOrNull(profileId);
    if (uid == null) return;
    for (final MapEntry<String, String> e
        in perProfileDeviceLocalPrefs.entries) {
      final String live = await _db.getPref(e.key) ?? '';
      final String parkedKey = '${e.value}$uid';
      if (await _db.getPref(parkedKey) == live) continue;
      await _db.setPref(parkedKey, live);
    }
  }

  /// 把 [profileId] 名下停放的值换回 live 键：空串 = 那份配置没选过，删掉 live 键；没停放过 = 不动。
  Future<void> _restorePerProfileDeviceLocalPrefs(int profileId) async {
    final String? uid = await _profileUidOrNull(profileId);
    if (uid == null) return;
    for (final MapEntry<String, String> e
        in perProfileDeviceLocalPrefs.entries) {
      final String? parked = await _db.getPref('${e.value}$uid');
      if (parked == null) continue;
      if (parked.isEmpty) {
        await _db.deletePref(e.key);
      } else {
        await _db.setPref(e.key, parked);
      }
    }
  }

  /// 全部媒体类型绑定的**裸串视图**（key = [ProfileMediaKind.dbValue]；DB 列
  /// 接受任意串，历史行可能含旧值域，原样透传不丢行）。
  Future<Map<String, int>> getAllMediaTypeBindings() async {
    final rows = await _db.getAllMediaTypeProfiles();
    return {for (final r in rows) r.mediaType: r.profileId};
  }

  Future<void> setMediaTypeBinding(ProfileMediaKind mediaType, int profileId) =>
      _db.setMediaTypeProfile(mediaType.dbValue, profileId);

  Future<void> removeMediaTypeBinding(ProfileMediaKind mediaType) =>
      _db.deleteMediaTypeProfile(mediaType.dbValue);

  /// 全部语言绑定（key = **归一化后**的语言标签，如 `ja` / `zh-Hant`）。
  ///
  /// 读侧也过一次 [normalizeLanguageBinding]：存量行理论上都是写侧归一过的，
  /// 但 DB 是自由文本列，手工改库 / 旧备份导入都可能塞进未归一的键。读侧再归一
  /// 一次让它们至少能被 UI 看见并改掉，而不是变成一行永远命不中的幽灵绑定。
  /// 归一后为空的行（`und` / 垃圾串）直接丢弃——它们不对应任何可路由的语言。
  Future<Map<String, int>> getAllLanguageBindings() async {
    final rows = await _db.getAllLanguageProfiles();
    final Map<String, int> out = <String, int>{};
    for (final r in rows) {
      final String key = normalizeLanguageBinding(r.languageTag);
      if (key.isEmpty) continue;
      out[key] = r.profileId;
    }
    return out;
  }

  /// 绑定一种内容语言到某 Profile。[languageTag] 可以是任意形态的 BCP-47 串，
  /// 落库前统一归一；归一后为空（语言不可识别）时不写入。
  Future<void> setLanguageBinding(String languageTag, int profileId) async {
    final String key = normalizeLanguageBinding(languageTag);
    if (key.isEmpty) return;
    await _db.setLanguageProfile(key, profileId);
  }

  Future<void> removeLanguageBinding(String languageTag) async {
    final String key = normalizeLanguageBinding(languageTag);
    if (key.isEmpty) return;
    await _db.deleteLanguageProfile(key);
  }

  Future<int?> getBookProfileId(String bookUid) async {
    final row = await _db.getBookProfile(bookUid);
    return row?.profileId;
  }

  Future<void> setBookProfile(String bookUid, int profileId) =>
      _db.setBookProfile(bookUid, profileId);

  Future<void> removeBookProfile(String bookUid) =>
      _db.deleteBookProfile(bookUid);

  /// 反馈 kEFPY4cuKZ：作品会话期间对作品级键（[key]，`preferences` 表键）的写入落到
  /// [profileId] 这份组合上（[raw] 为 null = 在这一层设为「未设置」）。目标组合由会话按叶子
  /// 来源选（[WorkProfileSession.targetProfileIdFor]）。
  ///
  /// [profileId] 此刻就是激活配置（默认组合，会话期间用户手动切到了它）时写 live 偏好——
  /// 激活配置的真值在 live 表里，切走时才快照；写快照会在下次切走时被 live 值覆盖掉。否则经
  /// [ComboRepository.writeSettings] 写进它自己的行，下次打开这类作品时生效。全局偏好绝不碰。
  Future<void> writeWorkScopedPref(
    int profileId,
    String key,
    String? raw,
  ) async {
    if (profileId == await getActiveProfileId()) {
      if (raw == null) {
        await _db.deletePref(key);
      } else {
        await _db.setPref(key, raw);
      }
      return;
    }
    await combos.writeSettings(profileId, <SettingKey, String?>{
      SettingKey(ProfileKeys.categoryPref, key): raw,
    });
  }

  /// 作品会话期间对 Anki 制卡设置的写入：[ankiMap]（[ProfileKeys.ankiSettingsToMap] 形的一部分，
  /// 配置拥有的字段）落到 [profileId] 这份组合上。与 [writeWorkScopedPref] 同一判据：
  /// [profileId] 此刻就是激活配置时叠到 live Anki 设置上。
  Future<void> writeWorkScopedAnkiSettings(
    int profileId,
    Map<String, String> ankiMap,
  ) async {
    if (profileId == await getActiveProfileId()) {
      final AnkiSettings current = await _ankiRepo.loadSettings();
      await _ankiRepo.saveSettings(
        ProfileKeys.mapToAnkiSettings(ankiMap, current),
      );
      return;
    }
    await combos.writeSettings(profileId, <SettingKey, String?>{
      for (final MapEntry<String, String> e in ankiMap.entries)
        SettingKey(ProfileKeys.categoryAnki, e.key): e.value,
    });
  }

  /// 制卡叶子的 key 只落在这两个 category（`fushi_settings_tree.dart` 的登记），现读 Anki 字段
  /// 时只解析它们，省掉词典元数据。
  static const Set<String> _miningCategories = <String>{
    ProfileKeys.categoryAnki,
    ProfileKeys.categoryPref,
  };

  /// 作品会话现读绑定层 [layers] 解析出的 Anki 字段（[ProfileKeys.ankiSettingsToMap] 形）；null =
  /// 制卡叶子全部继承默认组合，Anki 设置照旧读 live。每次现读持久层：Android 弹窗进程与主进程
  /// 各有一份会话，任一边写进组合的改动另一边下次读就看得到，读改写不会拿旧内存值覆盖对方。
  Future<Map<String, String>?> readWorkScopedAnki(
    Map<ComboScope, int> layers,
  ) async {
    final ResolvedComboStack stack = await combos.resolve(
      layers,
      categories: _miningCategories,
    );
    return workAnkiOverridesOf(stack);
  }

  /// [stack] 里制卡链要接管的 Anki 字段：任一认领 Anki 字段的叶子（[_ankiLeafIds]）来自绑定层
  /// 时，取全部解析出的 Anki 字段（继承默认的那几组就是 live 值）；全部继承默认时 null（读 live，
  /// 与旧版「绑定配置快照里没有 Anki 字段」同一处理）。
  static Map<String, String>? workAnkiOverridesOf(ResolvedComboStack stack) {
    if (!_ankiLeafIds.any((String l) => stack.sourceProfileIdOf(l) != null)) {
      return null;
    }
    return <String, String>{
      for (final MapEntry<SettingKey, String> e
          in stack.settings.values.entries)
        if (e.key.category == ProfileKeys.categoryAnki) e.key.key: e.value,
    };
  }

  /// 认领 Anki 字段的叶子（`fushi_settings_tree_test.dart` 守卫保证 Anki 快照字段只落在制卡叶子）。
  static const List<String> _ankiLeafIds = <String>[
    FushiComboNode.miningDeck,
    FushiComboNode.miningNoteType,
    FushiComboNode.miningTagsDupes,
    FushiComboNode.miningCardContent,
  ];

  /// 一部作品的绑定层：作品（`book_profiles`）/ 媒体类型（`media_type_profiles`）/ 内容语言
  /// （`language_profiles`）各自命中的 Profile。不回落到激活配置（它是最底层的默认组合，
  /// [ComboRepository.resolve] 自己会补）。
  ///
  /// [languageTag] 传原始内容语言串即可（内部归一）。**为空 / 不可识别时整层跳过**。调用方绝不
  /// 应为了「填一个值」而把全局默认内容语言喂进来：那会让所有未标注条目一起路由到同一个
  /// Profile，且用户改一次全局默认就整批跳档——那不是按语言绑定，是多了一个全局开关。
  Future<Map<ComboScope, int>> resolveBindingLayers({
    required String? bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  }) async {
    final Map<ComboScope, int> layers = <ComboScope, int>{};
    if (bookUid != null) {
      final int? bookProfileId = await getBookProfileId(bookUid);
      if (bookProfileId != null) layers[ComboScope.work] = bookProfileId;
    }
    if (mediaType != null) {
      final mtRow = await _db.getMediaTypeProfile(mediaType.dbValue);
      if (mtRow != null) layers[ComboScope.mediaType] = mtRow.profileId;
    }
    final String languageKey = normalizeLanguageBinding(languageTag);
    if (languageKey.isNotEmpty) {
      final langRow = await _db.getLanguageProfile(languageKey);
      if (langRow != null) layers[ComboScope.language] = langRow.profileId;
    }
    return layers;
  }

  /// 绑定层里优先级最高的那份 Profile，没有绑定时回落激活配置：**作品 > 媒体类型 > 语言 >
  /// 激活**（组合模型的生效顺序，拍板台 design-combo-node-split；旧版是语言高于媒体类型）。
  ///
  /// 只给「整份选一个配置」的调用方用（浏览器扩展按「浏览器」媒体类型绑定选配置）；作品会话
  /// 逐叶子解析全部绑定层（[resolveBindingLayers] + [ComboRepository.resolve]），不挑一份。
  Future<int> resolveProfileId({
    required String? bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  }) async =>
      (await resolveBoundProfileId(
        bookUid: bookUid,
        languageTag: languageTag,
        mediaType: mediaType,
      )) ??
      await getActiveProfileId();

  /// [resolveProfileId] 的绑定部分：只返回**绑定命中**的最高层 Profile，没命中返回 null
  /// （不回落到激活配置）。
  Future<int?> resolveBoundProfileId({
    required String? bookUid,
    String? languageTag,
    required ProfileMediaKind? mediaType,
  }) async {
    final Map<ComboScope, int> layers = await resolveBindingLayers(
      bookUid: bookUid,
      languageTag: languageTag,
      mediaType: mediaType,
    );
    for (final ComboScope scope in ComboScope.bindingLayers) {
      final int? id = layers[scope];
      if (id != null) return id;
    }
    return null;
  }

  // ── 导出 / 导入（单 Profile JSON 序列化）────────────────────────────

  /// 判断一个 pref key 是否属于「设备本地 / 凭据」，导出时必须剔除。
  ///
  /// 判定本身收敛到 [PrefRedactionPolicy]（备份 zip / Profile 快照 / 本分享
  /// JSON 三条出境通道共用的唯一真相源）。此前这里是一份独立实现，兜底被
  /// `if (!lower.startsWith('sync_')) return false;` 锁死在 `sync_` 家族，于是
  /// `media_source_secret_*`（SFTP/FTP 密码 + 私钥 PEM）、`qb_connection_config`
  /// （明文密码）与 `*_api_key` 全部漏网 —— 分享一个 Profile 就把它们一起送出去。
  static bool _isCredentialOrDeviceLocalPref(String key) =>
      PrefRedactionPolicy.isDeviceLocalOrCredential(key);

  /// 把单个 Profile 序列化成可分享的 JSON 字符串。
  ///
  /// - 激活 Profile：先 [snapshotCurrentSettings]（autosnapshot）把当前活的
  ///   偏好写进快照再读，保证导出的是最新状态。
  /// - 非激活 Profile：直读其已有快照，**不** snapshot（否则会用当前活偏好
  ///   污染那个 Profile 的快照）。
  /// - 凭据红线：导出前按 [_isCredentialOrDeviceLocalPref] 剔除全部凭据 /
  ///   设备本地 key（白名单为主、LIKE 兜底），绝不让 base64 凭据进文件。
  /// - 字体路径（A1）：把 `font_catalog` / 旧 shadow 列表里指向本机
  ///   `custom_fonts/` 的绝对路径剥成相对（rebase 到空根），导到别的设备时
  ///   该字体文件缺失则优雅降级（条目在、文件找不到、加载器跳过），不泄漏
  ///   本机目录结构、也不会指向不存在的绝对路径。[fontsRootDirectory] 为 null
  ///   （未知字体根）时跳过剥离，原样导出。
  ///
  /// 返回带缩进的 JSON 字符串。调用方负责落盘 / 分享。
  Future<String> exportProfileToJson(
    int profileId, {
    String? fontsRootDirectory,
  }) async {
    final ProfileRow? profile = await _db.getProfileById(profileId);
    if (profile == null) {
      throw ProfileImportException('profile $profileId not found');
    }

    final int activeId = await getActiveProfileId();
    if (profileId == activeId) {
      // 激活 Profile：导出前刷一次快照，确保拿到当前活偏好。
      await snapshotCurrentSettings(profileId);
    }

    // 组合格式的库：导出这份配置的**生效值全量**（组合 = 默认组合 + 它的拆分），仍是 v1 分享
    // 格式——别的设备 / 旧版本导入时当整份快照，不会把差异文档误当全量把没拆的设置全剪掉。
    // 组合格式元数据与复习库归属（本机复习数据的安排）不出本机。
    final List<({String category, String key, String value})> rows =
        await combos.defaultComboId() == null
        ? <({String category, String key, String value})>[
            for (final ProfileSettingRow r in await _db.getProfileSettings(
              profileId,
            ))
              (category: r.category, key: r.key, value: r.value),
          ]
        : <({String category, String key, String value})>[
            for (final MapEntry<SettingKey, String> e
                in (await _effectiveValuesOf(profileId)).entries)
              if (e.key.category != kComboSyntheticCategory)
                (category: e.key.category, key: e.key.key, value: e.value),
          ];

    final List<ProfileSettingEntry> settings = <ProfileSettingEntry>[];
    for (final ({String category, String key, String value}) row in rows) {
      // 凭据红线：唯一前置防线，剔除全部凭据 / 设备本地 key。
      if (row.category == ProfileKeys.categoryPref &&
          _isCredentialOrDeviceLocalPref(row.key)) {
        continue;
      }
      // 服务器词典的配置行 key 是 `<hostId>/<真名>`；老配对没有 hostId 时 hostId 是
      // 服务器地址（伪 id），导出会把地址带出本机——剔掉。真 hostId 不透明，照常导出。
      if (row.category == ProfileKeys.categoryRemoteDictionaryMeta) {
        final String? hostId = remoteDictionaryHostIdOfProfileKey(row.key);
        if (hostId == null || isRemoteDictionaryPseudoHostId(hostId)) continue;
      }
      settings.add(
        ProfileSettingEntry(
          category: row.category,
          key: row.key,
          value: _exportFontPathStrippedValue(
            category: row.category,
            key: row.key,
            value: row.value,
            fontsRootDirectory: fontsRootDirectory,
          ),
        ),
      );
    }

    return encodeProfileDocument(
      profileName: profile.name,
      schemaVersion: _db.schemaVersion,
      settings: settings,
    );
  }

  /// A1 字体路径剥离：把字体配置 JSON 里指向本机 `custom_fonts/` 的绝对路径
  /// 剥成相对（rebase 到空根）。非字体 key 原样返回。
  String _exportFontPathStrippedValue({
    required String category,
    required String key,
    required String value,
    required String? fontsRootDirectory,
  }) {
    if (fontsRootDirectory == null) return value;
    if (category != ProfileKeys.categoryPref) return value;
    if (key == _fontCatalogPrefKey) {
      return rebaseFontCatalogJson(value, fontsRootDirectory, '');
    }
    if (_legacyFontPrefKeys.contains(key)) {
      return rebaseFontListJson(value, fontsRootDirectory, '');
    }
    return value;
  }

  /// 字体配置的持久化 key（与 backup_service 同一组值；那边因 const 上下文
  /// 保留字面量并由 `db_source_pref_key_test` 锁一致）。这里经单一真相编码器
  /// [dbSourcePrefKey] 生成，不再硬编码 `src:reader_fushi:` 格式。
  static final String _fontCatalogPrefKey = dbSourcePrefKey(
    kReaderSourcePersistedKey,
    'font_catalog',
  );
  static final List<String> _legacyFontPrefKeys = <String>[
    dbSourcePrefKey(kReaderSourcePersistedKey, 'custom_fonts'),
    dbSourcePrefKey(kReaderSourcePersistedKey, 'app_ui_fonts'),
    dbSourcePrefKey(kReaderSourcePersistedKey, 'dict_fonts'),
    dbSourcePrefKey(kReaderSourcePersistedKey, 'video_sub_fonts'),
    dbSourcePrefKey(kReaderSourcePersistedKey, 'game_lookup_fonts'),
    dbSourcePrefKey(kReaderSourcePersistedKey, 'floating_lyric_fonts'),
    dbSourcePrefKey(kReaderSourcePersistedKey, 'srs_card_fonts'),
  ];

  /// 解析并校验一个导出 JSON 字符串。坏文件 / 魔数不符 / 版本不兼容 / 结构非法
  /// 一律抛 [ProfileImportException]（**在写 DB 之前**）。
  ProfileExport parseProfileExport(String json) => parseProfileDocument(json);

  /// 从导出 JSON 导回一个 Profile。
  ///
  /// 解析 + 校验阶段任何问题都在写 DB 前抛 [ProfileImportException]（事务零
  /// 破坏）。校验通过后：
  /// - [ProfileImportMode.createNew]（默认）：新建一个 Profile，名取自文件，
  ///   重名自动加后缀。
  /// - [ProfileImportMode.overwrite]：用文件内容覆盖 [targetProfileId] 指向的
  ///   已有 Profile 的设置（[replaceProfileSettings] 已是事务）；若覆盖的是当前
  ///   激活 Profile，调用方需再 [applyProfile] 让其立即生效。
  ///
  /// 返回写入的 Profile id。
  Future<int> importProfileFromJson(
    String json, {
    ProfileImportMode mode = ProfileImportMode.createNew,
    int? targetProfileId,
  }) async {
    final ProfileExport parsed = parseProfileExport(json);
    // 组合格式元数据 / 复习库归属是本机的安排，不从文件进来（本机导出也不带它们）。
    final ProfileExport export = ProfileExport(
      profileName: parsed.profileName,
      formatVersion: parsed.formatVersion,
      schemaVersion: parsed.schemaVersion,
      settings: <ProfileSettingEntry>[
        for (final ProfileSettingEntry e in parsed.settings)
          if (e.category != kComboSyntheticCategory) e,
      ],
    );
    final int? defaultId = await combos.defaultComboId();

    switch (mode) {
      case ProfileImportMode.createNew:
        if (defaultId == null) return importProfileDocumentAsNew(_db, export);
        // 组合格式的库：文件是整份快照，落成相对默认组合的差异（新的普通组合）。新行与它的
        // 设置在一个事务里落库：表变更监听方（常驻的配置列表）不会看到一份还没有设置的配置。
        final ComboDocument document = diffAgainstDefaults(
          tree: combos.tree,
          defaults: await _defaultComboValues(defaultId),
          snapshot: _importedValues(export),
        );
        return _db.transaction(() async {
          final int now = DateTime.now().millisecondsSinceEpoch;
          final int id = await _db.insertProfile(
            ProfilesCompanion.insert(
              name: await uniqueProfileName(_db, export.profileName),
              createdAt: now,
              updatedAt: now,
            ),
          );
          await combos.saveDocument(id, document);
          return id;
        });
      case ProfileImportMode.overwrite:
        if (targetProfileId == null) {
          throw ProfileImportException(
            'overwrite mode requires targetProfileId',
          );
        }
        final ProfileRow? target = await _db.getProfileById(targetProfileId);
        if (target == null) {
          throw ProfileImportException(
            'overwrite target $targetProfileId not found',
          );
        }
        // 覆盖激活配置后调用方会 [applyProfile]，它会把停放值换回 live 键；导入文件不带
        // 设备本地键，所以先把激活配置当前的 live 选择停放下来，免得换回切走那一刻的旧值。
        if (targetProfileId == await getActiveProfileId()) {
          await _parkPerProfileDeviceLocalPrefs(targetProfileId);
        }
        final DecodedComboRows targetRows = decodeComboRows(
          combos.tree,
          await combos.rowsOf(targetProfileId),
        );
        if (defaultId != null &&
            ComboRepository.isSplitDocument(targetRows) &&
            defaultId != targetProfileId) {
          // 覆盖一个组合：文件内容落成相对默认组合的差异；复习库归属（本机安排）保留。
          final ComboDocument imported = diffAgainstDefaults(
            tree: combos.tree,
            defaults: await _defaultComboValues(defaultId),
            snapshot: _importedValues(export),
          );
          final Map<String, Map<SettingKey, String>>? library =
              targetRows.document.splits[FushiComboNode.srsLibrary] == null
              ? null
              : <String, Map<SettingKey, String>>{
                  FushiComboNode.srsLibrary:
                      targetRows.document.splits[FushiComboNode.srsLibrary]!,
                };
          await combos.saveDocument(
            targetProfileId,
            ComboDocument(<String, Map<SettingKey, String>>{
              ...imported.splits,
              ...?library,
            }),
            role: targetRows.role!,
          );
          return targetProfileId;
        }
        // 整份快照（默认组合 / 存量快照）：组合格式元数据行留着，默认组合不因覆盖丢掉身份。
        await _db
            .replaceProfileSettings(targetProfileId, <ProfileSettingsCompanion>[
              ...profileSettingCompanions(export.settings, targetProfileId),
              for (final MapEntry<SettingKey, String> r in (await combos.rowsOf(
                targetProfileId,
              )).entries)
                if (r.key.category == kComboSyntheticCategory)
                  ProfileSettingsCompanion.insert(
                    profileId: targetProfileId,
                    category: r.key.category,
                    key: r.key.key,
                    value: r.value,
                  ),
            ]);
        return targetProfileId;
    }
  }

  // ── TODO-1077 dictionary_metadata snapshot serialization ────────────

  /// [applyProfile] 与 [loadSettingsView] 共用的快照解码：按类别拆成 Anki / 偏好 /
  /// 词典元数据三份，旧类别（legacy dictionary / reader）并进偏好。
  _DecodedProfileSnapshot _decodeSnapshot(List<ProfileSettingRow> rows) =>
      _decodeSettings(<SettingKey, String>{
        for (final ProfileSettingRow row in rows)
          SettingKey(row.category, row.key): row.value,
      });

  /// [_decodeSnapshot] 的本体，输入是 (category, key) → value（组合解析结果同形）。
  _DecodedProfileSnapshot _decodeSettings(Map<SettingKey, String> settings) {
    final ankiMap = <String, String>{};
    final prefMap = <String, String>{};
    // TODO-1077: snapshot rows for the dictionary_metadata table. `hasDictMeta`
    // distinguishes "profile has no dictionary_meta snapshot at all" (old
    // snapshot, pre-TODO-1077) from "profile intentionally has zero
    // dictionaries". Only the latter may prune the live table; the former MUST
    // be left untouched so a switch never wipes the shared dictionary config.
    final Map<String, DictionaryMetadataCompanion> dictMetaMap =
        <String, DictionaryMetadataCompanion>{};
    bool hasDictMeta = false;
    final Map<String, RemoteDictionaryProfileColumns> remoteDictMetaMap =
        <String, RemoteDictionaryProfileColumns>{};
    for (final MapEntry<SettingKey, String> entry in settings.entries) {
      final ({String category, String key, String value}) row = (
        category: entry.key.category,
        key: entry.key.key,
        value: entry.value,
      );
      switch (row.category) {
        case ProfileKeys.categoryAnki:
          ankiMap[row.key] = row.value;
        case ProfileKeys.categoryPref:
          prefMap[row.key] = row.value;
        case ProfileKeys.categoryDictionaryMeta:
          hasDictMeta = true;
          final DictionaryMetadataCompanion? companion = _decodeDictionaryMeta(
            row.key,
            row.value,
          );
          // Defensive: a single corrupt row degrades gracefully (skipped)
          // instead of aborting the whole profile-apply (mirrors the Anki
          // fieldMappings try/catch, HBK-AUDIT-043).
          if (companion != null) dictMetaMap[row.key] = companion;
        case ProfileKeys.categoryRemoteDictionaryMeta:
          // 坏行跳过（同上），不中断整次应用。
          final RemoteDictionaryProfileColumns? columns =
              decodeRemoteDictionaryProfileColumns(row.key, row.value);
          if (columns != null) remoteDictMetaMap[row.key] = columns;
        // Legacy categories from old snapshots
        case ProfileKeys.categoryDictionary:
          prefMap[row.key] = row.value;
        case ProfileKeys.categoryReader:
          // 旧快照里 reader 偏好按 MediaSource 命名空间还原；用单一真相编码器
          // 而非硬编码 `src:reader_fushi:` 猜下层私有 key 格式（[dbSourcePrefKey]）。
          prefMap[dbSourcePrefKey(kReaderSourcePersistedKey, row.key)] =
              row.value;
        default:
          break;
      }
    }

    // BUG-1019: old snapshots (taken before a key entered the exclusion list,
    // e.g. audiobook_pos_* / audiobook_speed_* / override_title://*) may still
    // carry excluded keys. Apply must neither restore those stale values (a
    // months-old speed/position overwriting the live one) nor delete the live
    // rows (the prune loop below already skips excluded keys) — so drop them
    // from the restore map here. Same single source of truth as snapshot/prune:
    // [ProfileKeys.isExcludedPref].
    prefMap.removeWhere(
      (String key, String _) => ProfileKeys.isExcludedPref(key),
    );
    return (
      ankiMap: ankiMap,
      prefMap: prefMap,
      dictMetaMap: dictMetaMap,
      hasDictMeta: hasDictMeta,
      remoteDictMetaMap: remoteDictMetaMap,
    );
  }

  /// [loadSettingsView] 从 live `preferences` 表直接取值（而不是从配置快照取）的键：不随配置走的
  /// 设备本地 / 凭据 / 状态键（[ProfileKeys.isExcludedPref]，含 Anki 设置整份 JSON）。其余键的值
  /// 只来自配置快照——App 激活配置改它们不影响别的配置的视图（视图缓存据此判断要不要重建）。
  static bool settingsViewReadsLivePref(String key) =>
      ProfileKeys.isExcludedPref(key);

  /// 反馈 biLEesNqWb：**只读**解析 [profileId] 的快照，得到「现在切到它会生效的整份
  /// 设置」（[ProfileSettingsView]），不写任何表、不动激活配置。配置不存在返回 null。
  ///
  /// 合成规则逐条对齐 [applyProfile]（两者共用 [_decodeSnapshot]）：
  /// * 偏好：live 里设备本地键（[ProfileKeys.isExcludedPref]）保留，其余键只取快照——
  ///   [applyProfile] 正是「删掉快照里没有的非排除键、写入快照键」；
  /// * 词典：live 行为底，快照里有同名行时换上配置拥有的列（顺序 / 隐藏 / 折叠 / 展开 /
  ///   语言覆盖 / 混合词典汉字部分开关）；没有 dictionary_meta 快照的老配置保持 live。
  ///   [applyProfile] 对「快照有、库里没有但磁盘还在」的行会自愈回插，视图不做——
  ///   App 自己的词典列表里也没有那一行，引擎加载的词典集合与之一致；
  /// * Anki：快照有 Anki 字段时 [ProfileKeys.mapToAnkiSettings] 叠在 live 设置上。
  ///
  /// 调用方若发现 [profileId] 就是激活配置，应直接用 live 状态：激活配置的快照只在
  /// 切走时才刷新，比 live 旧。
  Future<ProfileSettingsView?> loadSettingsView(int profileId) async {
    if (profileId <= 0) return null;
    final ProfileRow? profile = await _db.getProfileById(profileId);
    if (profile == null) return null;
    // 组合格式（只存被拆叶子）的 Profile：视图 = 它在默认组合之上的生效值。存量整份快照照旧
    // 直接用快照（与解析结果逐键一致，见 [ComboRepository] 的库文档）。
    if (await combos.isComboFormat(profileId)) {
      final ResolvedComboStack stack = await combos.resolve(<ComboScope, int>{
        ComboScope.mediaType: profileId,
      });
      return _viewFromSettings(
        profile: profile,
        snapshot: _decodeSettings(stack.settings.values),
        ankiSnapshot: workAnkiOverridesOf(stack) ?? const <String, String>{},
      );
    }
    final _DecodedProfileSnapshot snapshot = _decodeSnapshot(
      await _db.getProfileSettings(profileId),
    );
    return _viewFromSettings(
      profile: profile,
      snapshot: snapshot,
      ankiSnapshot: snapshot.ankiMap,
    );
  }

  /// 作品会话的分层视图：按绑定层 [layers] 逐叶子解析（作品 → 媒体类型 → 语言 → 默认），
  /// 用与 [loadSettingsView] 同一套合成规则做成只读视图。没有不同于默认组合（激活配置）的
  /// 绑定层时返回 null——作品没有自己的设置，读写都直达全局。
  ///
  /// 视图的 `profileId` / 名字取优先级最高的那层（诊断与查词缓存命名空间用；缓存键还带词典
  /// 过滤指纹，层组合不同、词典结果不同时不会撞）。按配置停放的设备本地键同样取那一层。
  Future<WorkComboView?> loadWorkComboView(Map<ComboScope, int> layers) async {
    final ResolvedComboStack stack = await combos.resolve(layers);
    final int? topId = stack.topProfileId;
    if (topId == null) return null;
    final ProfileRow? top = await _db.getProfileById(topId);
    if (top == null) return null;
    final Map<String, String>? anki = workAnkiOverridesOf(stack);
    final ProfileSettingsView view = await _viewFromSettings(
      profile: top,
      snapshot: _decodeSettings(stack.settings.values),
      ankiSnapshot: anki ?? const <String, String>{},
    );
    return WorkComboView(stack: stack, view: view);
  }

  /// [profile] 的只读视图：设置值来自 [snapshot]（存量快照或组合解析结果），合成规则见
  /// [loadSettingsView]。[ankiSnapshot] 是视图声明「自己拥有」的 Anki 字段（作品会话据此决定
  /// 接不接管 Anki 设置）。
  Future<ProfileSettingsView> _viewFromSettings({
    required ProfileRow profile,
    required _DecodedProfileSnapshot snapshot,
    required Map<String, String> ankiSnapshot,
  }) async {
    final Map<String, String> prefs = <String, String>{
      for (final MapEntry<String, String> e
          in (await _db.getAllPrefs()).entries)
        if (settingsViewReadsLivePref(e.key)) e.key: e.value,
      ...snapshot.prefMap,
    };
    // 按配置记的设备本地键：视图要的是这份配置自己的值（停放值），不是激活配置的 live 值；
    // 没停放过的配置切过去会沿用 live 值（[applyProfile]），视图同口径保留 live。
    final String uid = await _db.profileUidOf(profile.id);
    for (final MapEntry<String, String> e
        in perProfileDeviceLocalPrefs.entries) {
      final String? parked = prefs['${e.value}$uid'];
      if (parked == null) continue;
      if (parked.isEmpty) {
        prefs.remove(e.key);
      } else {
        prefs[e.key] = parked;
      }
    }

    final List<DictionaryMetaRow> liveRows = await _db
        .getAllDictionaryMetadata();
    final List<DictionaryMetaRow> rows = !snapshot.hasDictMeta
        ? liveRows
        : <DictionaryMetaRow>[
            for (final DictionaryMetaRow live in liveRows)
              _withProfileDictionaryColumns(
                live,
                snapshot.dictMetaMap[live.name],
              ),
          ];
    // 服务器托管词典：live 目录行换上快照里的顺序 / 开关（与 [applyProfile] 同一组列），
    // 只留此刻参与查词的 host（与 DictionaryRepository 同一判据）。
    final List<RemoteDictionaryMetaRow> remoteRows = <RemoteDictionaryMetaRow>[
      for (final RemoteDictionaryMetaRow live
          in await _db.getAllRemoteDictionaryMetadata())
        _withProfileRemoteDictionaryColumns(
          live,
          snapshot.remoteDictMetaMap[remoteDictionaryProfileKey(
            live.hostId,
            live.name,
          )],
        ),
    ];
    final Set<String> lookupHosts = remoteDictionaryLookupHostIdsOf(
      await SyncRepository(_db).getFushiClientUrls(),
    );

    final AnkiSettings liveAnki = await _ankiRepo.loadSettings();
    final AnkiSettings anki = snapshot.ankiMap.isEmpty
        ? liveAnki
        : ProfileKeys.mapToAnkiSettings(snapshot.ankiMap, liveAnki);

    return ProfileSettingsView(
      profileId: profile.id,
      profileName: profile.name,
      prefsMap: prefs,
      prefs: PreferencesRepository.readOnlySnapshot(_db, prefs),
      ankiSettings: anki,
      dictionaries: DictionaryRepository.dictionariesFromRows(rows),
      remoteDictionaries: DictionaryRepository.remoteDictionariesFromRows(
        remoteRows,
        lookupHosts,
      ),
      ankiSnapshot: ankiSnapshot,
    );
  }

  /// [live] 目录行换上快照里配置拥有的顺序 / 开关；快照没有这一行时原样返回。
  static RemoteDictionaryMetaRow _withProfileRemoteDictionaryColumns(
    RemoteDictionaryMetaRow live,
    RemoteDictionaryProfileColumns? columns,
  ) => columns == null
      ? live
      : live.copyWith(order: columns.order, hidden: columns.hidden);

  /// [live] 行换上快照 [companion] 里配置拥有的列（与 [applyProfile] 的
  /// `applyDictionaryMetaProfileColumns` 同一组列）；没有快照行时原样返回。
  static DictionaryMetaRow _withProfileDictionaryColumns(
    DictionaryMetaRow live,
    DictionaryMetadataCompanion? companion,
  ) {
    if (companion == null) return live;
    return live.copyWith(
      order: companion.order.value,
      hiddenLanguagesJson: companion.hiddenLanguagesJson.value,
      collapsedLanguagesJson: companion.collapsedLanguagesJson.value,
      expandedLanguagesJson: companion.expandedLanguagesJson.value,
      languageOverride: Value<String?>(companion.languageOverride.value),
      metadataJson:
          _metadataWithProfileKanjiPartSettings(
            live.metadataJson,
            companion.metadataJson.value,
          ) ??
          live.metadataJson,
    );
  }

  /// Serialize one `dictionary_metadata` row into the JSON value stored in a
  /// profile_settings row (key = dictionary name). Carries every profile-owned
  /// column: order, formatKey (source), type, and the language-visibility /
  /// metadata JSON blobs (kept as raw strings — they are already JSON).
  String _encodeDictionaryMeta(DictionaryMetaRow row) {
    return jsonEncode(<String, dynamic>{
      'order': row.order,
      'formatKey': row.formatKey,
      'type': row.type,
      'metadataJson': row.metadataJson,
      'hiddenLanguagesJson': row.hiddenLanguagesJson,
      'collapsedLanguagesJson': row.collapsedLanguagesJson,
      'expandedLanguagesJson': row.expandedLanguagesJson,
      'languageOverride': row.languageOverride,
    });
  }

  /// live 行的 metadataJson 换上快照里混合词典汉字部分的开关 / 位置
  /// （[kDictKanjiPartSettingKeys]）后的 JSON；无需改写时回 null（= 不写该列）。
  ///
  /// metadataJson 其余键是安装事实（重导 / 在线更新整份重建），profile 不回写；
  /// 但这两项是与 hiddenLanguages / order 同级的用户设置——不跟 profile 的话，
  /// 在一个 profile 里关掉混合词典的汉字卡，所有 profile 都一起关了，而它的术语
  /// 部分却按 profile 各自开关。快照里没有这两个键 = 该 profile 用默认值。
  static String? _metadataWithProfileKanjiPartSettings(
    String? liveMetadataJson,
    String snapshotMetadataJson,
  ) {
    if (liveMetadataJson == null) return null;
    final Object? live;
    final Object? snapshot;
    try {
      live = jsonDecode(liveMetadataJson);
      snapshot = jsonDecode(snapshotMetadataJson);
    } on FormatException {
      // 损坏的 JSON 不在这里修：live 行由词典仓库读取时处理，这里只是不碰它。
      return null;
    }
    if (live is! Map || snapshot is! Map) return null;
    final Map<dynamic, dynamic> liveMap = live;
    final Map<String, String> wanted = kanjiPartSettingsIn(<String, String>{
      for (final MapEntry<dynamic, dynamic> e in snapshot.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    });
    final bool unchanged = kDictKanjiPartSettingKeys.every(
      (String key) => liveMap[key] == wanted[key],
    );
    if (unchanged) return null;
    return jsonEncode(<String, dynamic>{
      for (final MapEntry<dynamic, dynamic> e in liveMap.entries)
        if (!kDictKanjiPartSettingKeys.contains(e.key)) '${e.key}': e.value,
      ...wanted,
    });
  }

  /// Decode a snapshot dictionary-meta value back into an upsert companion.
  /// Returns null (skip the row) on any malformed data — a single bad row must
  /// not abort the whole profile-apply (mirrors [ProfileKeys] Anki parsing,
  /// HBK-AUDIT-043). [name] is the profile_settings key (dictionary name / PK).
  DictionaryMetadataCompanion? _decodeDictionaryMeta(
    String name,
    String value,
  ) {
    try {
      final dynamic decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final Object? rawOrder = decoded['order'];
      final int order = rawOrder is int
          ? rawOrder
          : int.tryParse('$rawOrder') ?? 0;
      String asString(Object? v, String fallback) => v is String ? v : fallback;
      return DictionaryMetadataCompanion(
        name: Value(name),
        formatKey: Value(asString(decoded['formatKey'], '')),
        order: Value(order),
        type: Value(asString(decoded['type'], 'term')),
        metadataJson: Value(asString(decoded['metadataJson'], '{}')),
        hiddenLanguagesJson: Value(
          asString(decoded['hiddenLanguagesJson'], '[]'),
        ),
        collapsedLanguagesJson: Value(
          asString(decoded['collapsedLanguagesJson'], '[]'),
        ),
        // 旧快照没有这个键 → '[]' = 全部「继承」= 与 BUG-2158 之前的行为一致。
        expandedLanguagesJson: Value(
          asString(decoded['expandedLanguagesJson'], '[]'),
        ),
        // null（未指定）是合法值，不能像上面几个那样塞空串默认值——空串会让
        // effectiveSourceLanguage 的「非空即用户指定」判据失真。
        languageOverride: Value(
          decoded['languageOverride'] is String
              ? decoded['languageOverride'] as String
              : null,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 同一个库上在跑的 [ensureDefaultProfile]（按库对象分组：仓储有多个实例共用
  /// 一个库）。它是「先查有没有、没有就建 Default」：两路并发（视图模型首次加载 +
  /// 控制通道 / AI 的 reload）会都看见空表、都去建，第二路撞 `profiles.name` 唯一
  /// 约束（BUG-3784）。并发调用合并到同一次。
  static final Expando<Future<void>> _ensuringDefault = Expando<Future<void>>(
    'ensureDefaultProfile',
  );

  Future<void> ensureDefaultProfile() {
    final Future<void>? running = _ensuringDefault[_db];
    if (running != null) return running;
    final Future<void> ensuring = _ensureDefaultProfile().whenComplete(
      () => _ensuringDefault[_db] = null,
    );
    _ensuringDefault[_db] = ensuring;
    return ensuring;
  }

  Future<void> _ensureDefaultProfile() async {
    final existing = await _db.getAllProfiles();
    if (existing.isEmpty) {
      final id = await createProfile('Default');
      await setActiveProfileId(id);
      await snapshotCurrentSettings(id);
    } else {
      final activeId = await getActiveProfileId();
      final valid = existing.any((p) => p.id == activeId);
      if (!valid) {
        await setActiveProfileId(existing.first.id);
        await applyProfile(existing.first.id);
      }
    }
    await normalizeCombos();
  }

  // ── 组合格式（拍板台 design-combo-node-split 阶段 3）────────────────

  /// 把库里的 Profile 归一成「唯一默认组合 + 其余只存被拆叶子的组合」，并定复习库归属
  /// （design-srs-shared-library §4.2）。规划见引擎 [planComboMigration]；这里负责读输入、
  /// 先把激活配置快照成最新、写迁移备份、事务内落库、记迁移报告。
  ///
  /// 幂等：已经是唯一默认 + 组合格式、复习库也定过时只读两行就返回。旧备份恢复 / 合并导入
  /// 带进来的存量快照、两份默认组合，下一次调用都会收敛。只在主进程做（辅助进程只读）。
  ///
  /// 失败（备份写不了 / 落库出错）整体不改，异常抛给调用方；下次启动再试。
  Future<void> normalizeCombos() async {
    if (!_db.isMainProcess) return;
    final List<ProfileRow> profiles = await _db.getAllProfiles();
    if (profiles.isEmpty) return;
    final Map<int, String> roles = await _db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboRoleKey,
    );
    final List<int> defaults = <int>[
      for (final MapEntry<int, String> e in roles.entries)
        if (e.value == ComboRole.defaults.wire) e.key,
    ];
    final bool settingsPending =
        defaults.length != 1 ||
        profiles.any((ProfileRow p) => !roles.containsKey(p.id));
    final Map<int, String> sharedUids = await _db.profileSettingValuesOf(
      kComboSyntheticCategory,
      kComboSrsSharedUidKey,
    );
    final bool srsDecided = defaults.any(sharedUids.containsKey);
    if (!settingsPending && srsDecided) return;

    final int activeId = await getActiveProfileId();
    // 默认组合（多半就是激活配置）要是最新的活偏好。
    if (settingsPending && profiles.any((ProfileRow p) => p.id == activeId)) {
      await snapshotCurrentSettings(activeId);
    }
    final List<ComboMigrationProfile> inputs = <ComboMigrationProfile>[
      for (final ProfileRow p in profiles)
        ComboMigrationProfile(
          id: p.id,
          uid: await _db.profileUidOf(p.id),
          name: p.name,
          rows: await combos.rowsOf(p.id),
        ),
    ];
    Set<String>? srsUidsWithData;
    final ComboSrsUserDataProbe? probe = _srsUserData;
    if (!srsDecided && inputs.length > 1 && probe != null) {
      try {
        srsUidsWithData = await probe(<String>[
          for (final ComboMigrationProfile p in inputs) p.uid,
        ]);
      } on Object catch (e) {
        // 复习库此刻读不了：设置照常迁移，复习库归属留到下次。
        debugPrint('[profile] combo migration: srs probe failed: $e');
      }
    }
    final int? fallbackId = await getFallbackProfileId();
    final ComboMigrationPlan plan = planComboMigration(
      tree: combos.tree,
      profiles: inputs,
      preferredDefaultIds: <int>[?fallbackId, activeId],
      bindings: ComboMigrationBindings(
        mediaType: await getAllMediaTypeBindings(),
        language: await getAllLanguageBindings(),
        work: <String, int>{
          for (final BookProfileRow r in await _db.getAllBookProfiles())
            r.bookKey: r.profileId,
        },
      ),
      srsUidsWithData: srsUidsWithData,
    );
    if (plan.isNoop) return;
    // 改写存量快照前先把原样整份落盘（撤销途径）；写不了就整个不改。
    if (plan.report != null) await _writeComboMigrationBackup(inputs);
    await _db.transaction(() async {
      for (final MapEntry<int, Map<SettingKey, String>> e
          in plan.rewrites.entries) {
        await _db.replaceProfileSettings(e.key, <ProfileSettingsCompanion>[
          for (final MapEntry<SettingKey, String> r in e.value.entries)
            ProfileSettingsCompanion.insert(
              profileId: e.key,
              category: r.key.category,
              key: r.key.key,
              value: r.value,
            ),
        ]);
      }
    });
    final ComboMigrationReport? report = plan.report;
    if (report != null) {
      await _db.setPref(
        kComboMigrationReportPrefKey,
        jsonEncode(report.toJson()),
      );
      await _db.setPref(
        kComboMigrationNoticePendingPrefKey,
        PrefCodec.encode(true),
      );
    } else if (plan.srs != null) {
      // 复习库结论晚于设置迁移定下：补进已有的报告（报告还没提示过就一起提示）。
      final ComboMigrationReport? stored = await loadComboMigrationReport();
      if (stored != null) {
        await _db.setPref(
          kComboMigrationReportPrefKey,
          jsonEncode(stored.withSrs(plan.srs!).toJson()),
        );
      }
    }
  }

  /// 本库最近一次组合迁移的报告；没有 / 读不懂时 null。
  Future<ComboMigrationReport?> loadComboMigrationReport() async {
    final String? raw = await _db.getPref(kComboMigrationReportPrefKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? json = jsonDecode(raw);
      return json is Map<String, Object?>
          ? ComboMigrationReport.tryParse(json)
          : null;
    } on FormatException {
      return null;
    }
  }

  /// 报告还没提示过时取出并清掉「待提示」标记（标记先清再显示：显示途中被杀不会再弹一遍）。
  Future<ComboMigrationReport?> takePendingComboMigrationReport() async {
    final String? pending = await _db.getPref(
      kComboMigrationNoticePendingPrefKey,
    );
    if (pending == null) return null;
    await _db.deletePref(kComboMigrationNoticePendingPrefKey);
    if (!PrefCodec.decode<bool>(pending, false)) return null;
    return loadComboMigrationReport();
  }

  /// 迁移前把每份 Profile 的原行（剔掉凭据 / 设备本地偏好）写成一个 JSON 文件。
  Future<void> _writeComboMigrationBackup(
    List<ComboMigrationProfile> profiles,
  ) async {
    final Future<Directory> Function()? dirOf = _comboMigrationBackupDirectory;
    if (dirOf == null) return;
    final Directory dir = await dirOf();
    await dir.create(recursive: true);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final File file = File(
      '${dir.path}${Platform.pathSeparator}combo_$now.json',
    );
    final String body = const JsonEncoder.withIndent(' ').convert(
      <String, Object?>{
        'createdAt': now,
        'schemaVersion': _db.schemaVersion,
        'profiles': <Object?>[
          for (final ComboMigrationProfile p in profiles)
            <String, Object?>{
              'id': p.id,
              'uid': p.uid,
              'name': p.name,
              'rows': <Object?>[
                for (final MapEntry<SettingKey, String> r in p.rows.entries)
                  if (!(r.key.category == ProfileKeys.categoryPref &&
                      _isCredentialOrDeviceLocalPref(r.key.key)))
                    <String>[r.key.category, r.key.key, r.value],
              ],
            },
        ],
      },
    );
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(file.path);
  }

  /// 默认组合 [defaultId] 此刻的全量值：它是激活配置时是活偏好，否则是它的行。
  Future<Map<SettingKey, String>> _defaultComboValues(int defaultId) async =>
      defaultId == await getActiveProfileId()
      ? currentSettings()
      : _storedComboValues(defaultId);

  /// [profileId] 行里的设置值（去掉组合格式元数据；旧 category 已归一）。
  Future<Map<SettingKey, String>> _storedComboValues(int profileId) async =>
      decodeComboRows(combos.tree, await combos.rowsOf(profileId)).values;

  /// 组合 [profileId]（文档 [document]）在默认组合之上的生效值（应用 / 导出用）。库里暂时没有
  /// 默认组合（坏状态，下一次 [normalizeCombos] 会补）时以活偏好为底——宁可沿用，不剪光。
  Future<Map<SettingKey, String>> _effectiveOverDefault(
    int profileId,
    ComboDocument document,
  ) async {
    final int? defaultId = await combos.defaultComboId();
    final Map<SettingKey, String> base = defaultId == null
        ? await currentSettings()
        : await _defaultComboValues(defaultId);
    return resolveCombos(
      tree: combos.tree,
      defaults: base,
      layers: <ComboLayer>[
        ComboLayer(
          // 激活 / 导出的是整份配置：所有叶子都能拆的层。
          scope: ComboScope.mediaType,
          comboRef: await _db.profileUidOf(profileId),
          document: document,
        ),
      ],
    ).values;
  }

  /// [profileId] 这份配置的生效值全量：激活配置 = 活偏好；组合 = 默认之上的解析值；全量快照
  /// （默认组合 / 存量快照）= 它的行。
  Future<Map<SettingKey, String>> _effectiveValuesOf(int profileId) async {
    if (profileId == await getActiveProfileId()) return currentSettings();
    final DecodedComboRows decoded = decodeComboRows(
      combos.tree,
      await combos.rowsOf(profileId),
    );
    if (!ComboRepository.isSplitDocument(decoded)) return decoded.values;
    return _effectiveOverDefault(profileId, decoded.document);
  }

  /// 导入文件里的设置值（准入过滤 + 旧 category 归一），diff 用。
  Map<SettingKey, String> _importedValues(ProfileExport export) {
    final Map<SettingKey, String> modern = <SettingKey, String>{};
    final Map<SettingKey, String> legacy = <SettingKey, String>{};
    for (final ProfileSettingEntry e in export.settings) {
      if (!isAcceptedProfileSettingEntry(e)) continue;
      final SettingKey raw = SettingKey(e.category, e.key);
      final SettingKey k = normalizeLegacySettingKey(raw);
      (identical(k, raw) ? modern : legacy)[k] = e.value;
    }
    return <SettingKey, String>{...legacy, ...modern};
  }

  /// 把 [newDefaultId] 提升成默认组合（原默认 [previousDefaultId] 要被删掉）：新默认的行 = 它
  /// 此刻的生效值全量；其余组合改基到新默认（[rebaseComboDocument]，生效值不变）；共享复习库
  /// 指向的是被删那份时改指新默认。
  Future<void> _promoteToDefault(
    int newDefaultId, {
    required int previousDefaultId,
  }) async {
    final Map<SettingKey, String> oldBase = await _defaultComboValues(
      previousDefaultId,
    );
    final DecodedComboRows oldDefault = decodeComboRows(
      combos.tree,
      await combos.rowsOf(previousDefaultId),
    );
    final Map<SettingKey, String> newBase = <SettingKey, String>{
      for (final MapEntry<SettingKey, String> e in (await _effectiveValuesOf(
        newDefaultId,
      )).entries)
        if (e.key.category != kComboSyntheticCategory) e.key: e.value,
    };
    final Map<int, (ComboDocument, ComboRole)> rebased =
        <int, (ComboDocument, ComboRole)>{};
    for (final ProfileRow p in await _db.getAllProfiles()) {
      if (p.id == newDefaultId || p.id == previousDefaultId) continue;
      final DecodedComboRows d = decodeComboRows(
        combos.tree,
        await combos.rowsOf(p.id),
      );
      if (!ComboRepository.isSplitDocument(d)) continue;
      final ResolvedSettings effective = resolveCombos(
        tree: combos.tree,
        defaults: oldBase,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.mediaType,
            comboRef: await _db.profileUidOf(p.id),
            document: d.document,
          ),
        ],
      );
      rebased[p.id] = (
        rebaseComboDocument(
          tree: combos.tree,
          existing: d.document,
          base: newBase,
          effective: effective.values,
        ),
        d.role!,
      );
    }
    final String previousUid = await _db.profileUidOf(previousDefaultId);
    final String? oldShared = oldDefault.srsSharedUid;
    final String shared = oldShared == null || oldShared == previousUid
        ? await _db.profileUidOf(newDefaultId)
        : oldShared;
    await _db.transaction(() async {
      for (final MapEntry<int, (ComboDocument, ComboRole)> e
          in rebased.entries) {
        await combos.saveDocument(e.key, e.value.$1, role: e.value.$2);
      }
      await _db.replaceProfileSettings(newDefaultId, <ProfileSettingsCompanion>[
        for (final MapEntry<SettingKey, String> r in <SettingKey, String>{
          ...newBase,
          const SettingKey(kComboSyntheticCategory, kComboRoleKey):
              ComboRole.defaults.wire,
          const SettingKey(kComboSyntheticCategory, kComboSrsSharedUidKey):
              shared,
        }.entries)
          ProfileSettingsCompanion.insert(
            profileId: newDefaultId,
            category: r.key.category,
            key: r.key.key,
            value: r.value,
          ),
      ]);
      // 原默认的 role 行先撤掉：删除前的这一刻库里也只有一份默认。
      await _db.deleteProfileSetting(
        previousDefaultId,
        kComboSyntheticCategory,
        kComboRoleKey,
      );
    });
  }
}

/// [ProfileRepository._decodeSnapshot] 的结果。
typedef _DecodedProfileSnapshot = ({
  Map<String, String> ankiMap,
  Map<String, String> prefMap,
  Map<String, DictionaryMetadataCompanion> dictMetaMap,
  bool hasDictMeta,
  Map<String, RemoteDictionaryProfileColumns> remoteDictMetaMap,
});

/// 作品会话的分层解析结果（[ProfileRepository.loadWorkComboView]）。
class WorkComboView {
  const WorkComboView({required this.stack, required this.view});

  /// 逐叶子的生效值与来源（写入按叶子来源路由，见 `WorkProfileSession`）。
  final ResolvedComboStack stack;

  /// 解析结果做成的只读设置视图（查词过滤 / 作品级键 / Anki 字段取它）。
  final ProfileSettingsView view;
}
