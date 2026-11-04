import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show kReaderSourcePersistedKey;

import 'package:fushi/src/media/media_source.dart' show dbSourcePrefKey;
import 'package:fushi/src/models/preference_keys.dart'
    show kWorkProfileSessionPrefKey;
import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository, kFloatingLyricWindowRectPrefKey;
import 'package:fushi/src/models/theme_notifier.dart' show ThemeNotifier;
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi/src/models/preference_keys.dart'
    show kWorkProfileSessionPrefKey;

/// 把一条作品级配置设置写回它所属配置（Profile）的持久层；[raw] 为 null = 删除。
typedef WorkProfilePrefWriter =
    Future<void> Function(int profileId, String key, String? raw);

/// 把作品级配置的 Anki 制卡设置（[ProfileKeys.ankiSettingsToMap] 那几个配置拥有的字段）写回
/// 它所属配置的持久层。
typedef WorkProfileAnkiWriter =
    Future<void> Function(int profileId, Map<String, String> ankiMap);

/// 从持久层现读作品级配置此刻拥有的 Anki 字段（空 = 快照没有 Anki 字段）。
typedef WorkProfileAnkiReader =
    Future<Map<String, String>> Function(int profileId);

/// 解析 [kWorkProfileSessionPrefKey] 的值；空 / 坏值 = 没有会话。
int? parseWorkProfileSessionProfileId(String raw) {
  final int colon = raw.indexOf(':');
  final int? id = int.tryParse(colon < 0 ? raw : raw.substring(0, colon));
  return id != null && id > 0 ? id : null;
}

/// 反馈 kEFPY4cuKZ：一次「打开作品」期间生效的作品级配置（绑定命中的 Profile）。
///
/// 它是**会话作用域的覆盖层**，不是一次全局切换：App 的激活配置、`preferences` 表、
/// `dictionary_metadata` 表、live Anki 设置一概不动。会话期间改从这里读的设置——
///
/// * 阅读样式与字体：阅读器命名空间 `src:reader_fushi:*`（含字体目录与各用途字体表）；
/// * 有声书悬浮字幕样式：`floating_lyric_*`（窗口位置除外）；
/// * 主题：[ThemeNotifier.isProfileThemePrefKey]；
/// * 视频字幕样式：[WorkProfileScope.videoSubtitleStylePrefKeys]；
/// * 复习制卡目标：[WorkProfileScope.srsMiningPrefKeys]（目标 / 牌组 / 笔记类型 / 字段映射）；
/// * Anki 制卡设置：牌组 / 笔记类型 / 字段映射 / 标签 / 查重范围（[ankiOverrides]）；
/// * 查词：词典启用 / 顺序过滤（[view] 的 `lookupFilters`）。
///
/// 会话期间对这些设置的写入落到**绑定配置**自己的快照，离开作品时会话整个丢掉，读回落到
/// 全局——没有任何「切回去」的写入，崩溃 / 杀进程也不会把全局配置留在作品配置上。
class WorkProfileSession {
  WorkProfileSession({
    required this.owner,
    required this.view,
    required WorkProfilePrefWriter writer,
    WorkProfileAnkiWriter? ankiWriter,
    WorkProfileAnkiReader? ankiReader,
  }) : _writer = writer,
       _ankiWriter = ankiWriter,
       _ankiReader = ankiReader,
       prefs = <String, String>{
         for (final MapEntry<String, String> e in view.prefsMap.entries)
           if (WorkProfileScope.isWorkScopedPrefKey(e.key)) e.key: e.value,
       },
       ankiOverrides = view.ankiSnapshot.isEmpty
           ? null
           : Map<String, String>.of(view.ankiSnapshot);

  /// 会话的持有者（阅读器页 / 视频页 / 漫画页 / gal hook 会话控制器……）。
  final Object owner;

  /// 绑定配置的只读设置视图（查词过滤取它）。
  final ProfileSettingsView view;

  /// 绑定配置 id。
  int get profileId => view.profileId;

  /// 会话期间生效的作品级键（原始编码值，键同 `preferences` 表）。会话内写入只改这里 +
  /// 绑定配置的快照。
  final Map<String, String> prefs;

  /// 绑定配置拥有的 Anki 字段（[ProfileKeys.ankiSettingsToMap] 形）；null = 绑定配置的快照里
  /// 没有 Anki 字段，Anki 设置照旧读 live（与 `applyProfile` 对空 Anki 快照的处理一致）。
  /// 会话内改 Anki 设置后变为非 null。
  Map<String, String>? ankiOverrides;

  final WorkProfilePrefWriter _writer;
  final WorkProfileAnkiWriter? _ankiWriter;
  final WorkProfileAnkiReader? _ankiReader;
}

/// 进程内唯一的作品级配置覆盖层登记处（见 [WorkProfileSession]）。
///
/// 多个作品同时「打开」时（阅读器开着又启动了游戏），**最近进入**的会话生效；任一持有者
/// 离开只撤掉自己那一层。读侧（`PreferencesRepository` / `MediaSource` / `ReaderSettings` /
/// `ThemeNotifier` / 制卡用的 Anki 设置存储 / 本机查词）在没有会话时与引入覆盖层之前逐字节
/// 一致。
///
/// 进程（isolate）级状态：Android `:popup` 进程 / 悬浮词典 engine 各有一份，主进程经
/// [kWorkProfileSessionPrefKey] 发布当前会话，弹窗侧镜像进同一套覆盖层。
class WorkProfileScope extends ChangeNotifier {
  WorkProfileScope._();

  /// 进程唯一实例（与 `ReaderFushiSource.readerSettings` 同为进程级状态）。
  static final WorkProfileScope instance = WorkProfileScope._();

  final List<WorkProfileSession> _sessions = <WorkProfileSession>[];

  /// 已发起进入、视图尚未解析完的持有者：解析期间持有者就离开了，迟到的视图不得再装上。
  final Set<Object> _pending = Set<Object>.identity();

  /// [leaveWhen] 挂的结束监听（持有者 → 撤监听）。
  final Map<Object, VoidCallback> _endWatchers =
      Map<Object, VoidCallback>.identity();

  static final String _readerPrefix = dbSourcePrefKey(
    kReaderSourcePersistedKey,
    '',
  );

  /// 视频字幕样式（字幕外观 JSON + 「尊重 ASS 自带样式」）。字幕字体在阅读器命名空间的
  /// `video_sub_fonts`，随字体一起走。
  static const Set<String> videoSubtitleStylePrefKeys = <String>{
    'video_subtitle_style',
    'video_respect_ass_style',
  };

  /// 挖词目标 = Fushi 复习时的制卡目标：目标本身 + 牌组 / 笔记类型 / 字段映射。牌组与笔记
  /// 类型 id 带配置 uid，会话期间制卡落进绑定配置自己的复习副本（`_readSrsMiner`）。
  static const Set<String> srsMiningPrefKeys = <String>{
    PreferencesRepository.srsMiningTargetKey,
    'srs_mining_deck_id',
    'srs_mining_note_type_id',
    'srs_mining_field_mappings',
  };

  /// [key]（`preferences` 表键）是否作品级键：会话期间读写都走覆盖层。设备本地键
  /// （[ProfileKeys.isExcludedPref]）从不随配置走，也就从不进覆盖层。
  static bool isWorkScopedPrefKey(String key) {
    if (ProfileKeys.isExcludedPref(key)) return false;
    if (key.startsWith(_readerPrefix)) return true;
    if (key.startsWith('floating_lyric_')) {
      return key != kFloatingLyricWindowRectPrefKey;
    }
    return videoSubtitleStylePrefKeys.contains(key) ||
        srsMiningPrefKeys.contains(key) ||
        ThemeNotifier.isProfileThemePrefKey(key);
  }

  /// 当前生效的会话；null = 没有打开的作品带着作品级配置。
  WorkProfileSession? get active => _sessions.isEmpty ? null : _sessions.last;

  /// 本机查词应按哪份配置的视图过滤词典；null = App 当前生效的词典设置。
  ProfileSettingsView? get lookupView => active?.view;

  /// 会话是否接管 [key]：有会话且 [key] 是作品级键。
  bool overrides(String key) => active != null && isWorkScopedPrefKey(key);

  /// 会话里 [key] 的原始编码值（调用方先确认 [overrides]）；null = 绑定配置里没有这个键
  /// （按默认值，与切到该配置后的行为一致）。
  String? scopedRaw(String key) => active?.prefs[key];

  /// 全局偏好 [global] 叠上当前会话后的整份偏好：作品级键整体换成会话里的那一份。没有会话
  /// 时原样返回 [global]（同一个对象）。
  Map<String, String> effectivePrefs(Map<String, String> global) {
    final WorkProfileSession? session = active;
    if (session == null) return global;
    return <String, String>{
      for (final MapEntry<String, String> e in global.entries)
        if (!isWorkScopedPrefKey(e.key)) e.key: e.value,
      ...session.prefs,
    };
  }

  /// 会话内写入次数（每次 [write] / [writeAnki] 递增）。装上 / 撤下会话走 [notifyListeners]，
  /// 会话内写入不触发整套缓存重读，只经它告诉跨进程发布者「绑定配置的快照变了」。
  final ValueNotifier<int> writeRevision = ValueNotifier<int>(0);

  /// 会话内写入作品级键 [key]（[raw] 为 null = 删除）：内存同步改、绑定配置的持久层异步写。
  /// 调用方先确认 [overrides]。
  Future<void> write(String key, String? raw) async {
    final WorkProfileSession? session = active;
    if (session == null) return;
    if (raw == null) {
      session.prefs.remove(key);
    } else {
      session.prefs[key] = raw;
    }
    try {
      await session._writer(session.profileId, key, raw);
    } catch (e, stack) {
      ErrorLogService.instance.log('WorkProfileScope.write', e, stack);
    }
    writeRevision.value++;
  }

  /// 当前会话接管的 Anki 字段；null = 没有会话，或绑定配置不覆盖 Anki 设置。
  Map<String, String>? get ankiOverrides => active?.ankiOverrides;

  /// 现读当前会话接管的 Anki 字段（经会话的持久层读取器，读到后刷新 [ankiOverrides]）；null =
  /// 没有会话，或绑定配置不覆盖 Anki 设置。读失败留痕后用内存里的那份。
  ///
  /// 制卡链的读改写（`WorkScopedAnkiSettingsStore`）走这里而不是 [ankiOverrides]：Android 弹窗
  /// 进程在同一会话里改过绑定配置的牌组时，主进程内存里那份是旧的，拿它读改写会把弹窗的改动
  /// 整组覆盖掉。
  Future<Map<String, String>?> readAnki() async {
    final WorkProfileSession? session = active;
    if (session == null) return null;
    final WorkProfileAnkiReader? reader = session._ankiReader;
    if (reader == null) return session.ankiOverrides;
    try {
      final Map<String, String> fresh = await reader(session.profileId);
      session.ankiOverrides = fresh.isEmpty ? null : fresh;
    } catch (e, stack) {
      ErrorLogService.instance.log('WorkProfileScope.readAnki', e, stack);
    }
    return session.ankiOverrides;
  }

  /// 会话内写入 Anki 制卡设置里配置拥有的字段 [ankiMap]：内存同步改、绑定配置的持久层异步写。
  /// 没有会话时什么都不做（调用方写 live）。
  Future<void> writeAnki(Map<String, String> ankiMap) async {
    final WorkProfileSession? session = active;
    if (session == null) return;
    session.ankiOverrides = Map<String, String>.of(ankiMap);
    final WorkProfileAnkiWriter? writer = session._ankiWriter;
    if (writer == null) return;
    try {
      await writer(session.profileId, ankiMap);
    } catch (e, stack) {
      ErrorLogService.instance.log('WorkProfileScope.writeAnki', e, stack);
    }
    writeRevision.value++;
  }

  /// 进入 [resolveProfileId] 解析出的那份配置的作品会话（[owner] 持有）：取它的只读设置视图
  /// 装成覆盖层，写入经 [repository] 落到它自己的快照。解析结果为 null、就是激活配置、已不
  /// 存在或解析失败时撤掉 [owner] 之前的那层。返回 false = [owner] 在解析期间已离开，什么都
  /// 没装（解析放在 [begin] 之后跑，正是为了接住这种离开）。
  ///
  /// 本进程的作品入口（`ProfileViewModel.enterWorkSession`）与 Android 弹窗进程镜像主进程
  /// 的会话（`AppModel.mirrorMainProcessWorkSession`）共用这一条，不各写一份。
  Future<bool> enterProfile({
    required Object owner,
    required ProfileRepository repository,
    required Future<int?> Function() resolveProfileId,
  }) async {
    begin(owner);
    WorkProfileSession? session;
    try {
      final int? profileId = await resolveProfileId();
      if (profileId != null &&
          profileId != await repository.getActiveProfileId()) {
        final ProfileSettingsView? view = await repository.loadSettingsView(
          profileId,
        );
        if (view != null) {
          session = WorkProfileSession(
            owner: owner,
            view: view,
            writer: repository.writeWorkScopedPref,
            ankiWriter: repository.writeWorkScopedAnkiSettings,
            ankiReader: repository.readWorkScopedAnkiSettings,
          );
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('WorkProfileScope.enterProfile', e, stack);
    }
    return install(owner, session);
  }

  /// 主进程要发布给 Android 弹窗进程的当前会话值（[kWorkProfileSessionPrefKey]）：
  /// `<配置 id>:<会话内写入次数>`，没有会话 = 空串。写入次数让弹窗进程在同一会话里改过
  /// 绑定配置快照后也能经 `prefs_version` 看到变化、重新镜像。
  String get publishedSessionValue {
    final WorkProfileSession? session = active;
    return session == null ? '' : '${session.profileId}:${writeRevision.value}';
  }

  /// 弹窗进程：按主进程发布的值 [published]（[publishedSessionValue] 形）装上 / 换掉 / 撤下
  /// [owner] 的会话——走与主进程同一条 [enterProfile]，不另写一份作品配置逻辑。坏值 / 空值 =
  /// 主进程没有会话，撤掉。
  Future<void> mirrorPublishedSession({
    required Object owner,
    required String published,
    required ProfileRepository repository,
  }) async {
    final int? profileId = parseWorkProfileSessionProfileId(published);
    if (profileId == null) {
      leave(owner);
      return;
    }
    await enterProfile(
      owner: owner,
      repository: repository,
      resolveProfileId: () async => profileId,
    );
  }

  /// 登记 [owner] 即将进入（视图解析前调用），与 [install] 配对。
  void begin(Object owner) {
    _pending.add(owner);
  }

  /// 装上 [owner] 的会话；[session] 为 null = 该作品没有不同于激活配置的绑定（撤掉
  /// [owner] 之前的那层）。[owner] 在解析期间已经离开时什么都不做，返回 false。
  bool install(Object owner, WorkProfileSession? session) {
    if (!_pending.remove(owner)) return false;
    final WorkProfileSession? before = active;
    _sessions.removeWhere((WorkProfileSession s) => identical(s.owner, owner));
    if (session != null) _sessions.add(session);
    if (!identical(before, active)) notifyListeners();
    return true;
  }

  /// [owner] 离开作品：撤掉它的会话（不在栈顶也照撤）。
  void leave(Object owner) {
    _pending.remove(owner);
    final VoidCallback? unwatch = _endWatchers.remove(owner);
    unwatch?.call();
    final WorkProfileSession? before = active;
    _sessions.removeWhere((WorkProfileSession s) => identical(s.owner, owner));
    if (!identical(before, active)) notifyListeners();
  }

  /// [listenable] 每次通知时问一次 [ended]，为 true 就 [leave] [owner]。用于没有页面生命
  /// 周期的会话（gal hook：游戏退出 / 停止捕获即离开作品）。注册时已结束则立即离开。
  void leaveWhen(Object owner, Listenable listenable, bool Function() ended) {
    _endWatchers.remove(owner)?.call();
    void check() {
      if (ended()) leave(owner);
    }

    listenable.addListener(check);
    _endWatchers[owner] = () => listenable.removeListener(check);
    check();
  }

  /// 测试收尾：清空全部会话与监听。
  @visibleForTesting
  void debugReset() {
    for (final VoidCallback unwatch in _endWatchers.values) {
      unwatch();
    }
    _endWatchers.clear();
    _pending.clear();
    final bool hadSession = _sessions.isNotEmpty;
    _sessions.clear();
    writeRevision.value = 0;
    if (hadSession) notifyListeners();
  }
}
