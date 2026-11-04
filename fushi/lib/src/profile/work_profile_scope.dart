import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show kReaderSourcePersistedKey;

import 'package:fushi/src/media/media_source.dart' show dbSourcePrefKey;
import 'package:fushi/src/models/preferences_repository.dart'
    show kFloatingLyricWindowRectPrefKey;
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_settings_view.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 把一条作品级配置设置写回它所属配置（Profile）的持久层；[raw] 为 null = 删除。
typedef WorkProfilePrefWriter =
    Future<void> Function(int profileId, String key, String? raw);

/// 反馈 kEFPY4cuKZ：一次「打开作品」期间生效的作品级配置（绑定命中的 Profile）。
///
/// 它是**会话作用域的覆盖层**，不是一次全局切换：App 的激活配置、`preferences` 表、
/// `dictionary_metadata` 表一概不动。只有三类设置在会话期间改从这里读——
///
/// * 阅读样式：阅读器命名空间 `src:reader_fushi:*`（字体目录 / 字体用途表除外，它们同时
///   承载 App 界面字体等全局用途）；
/// * 有声书悬浮字幕样式：`floating_lyric_*`（窗口位置除外）；
/// * 查词：词典启用 / 顺序过滤（[view] 的 `lookupFilters`）。
///
/// 会话期间对这些键的写入落到**绑定配置**自己的快照，离开作品时会话整个丢掉，读回落到
/// 全局——没有任何「切回去」的写入，崩溃 / 杀进程也不会把全局配置留在作品配置上。
class WorkProfileSession {
  WorkProfileSession({
    required this.owner,
    required this.view,
    required WorkProfilePrefWriter writer,
  }) : _writer = writer,
       prefs = <String, String>{
         for (final MapEntry<String, String> e in view.prefsMap.entries)
           if (WorkProfileScope.isWorkScopedPrefKey(e.key)) e.key: e.value,
       };

  /// 会话的持有者（阅读器页 / 视频页 / 漫画页 / gal hook 会话控制器……）。
  final Object owner;

  /// 绑定配置的只读设置视图（查词过滤取它）。
  final ProfileSettingsView view;

  /// 绑定配置 id。
  int get profileId => view.profileId;

  /// 会话期间生效的作品级键（原始编码值，键同 `preferences` 表）。会话内写入只改这里 +
  /// 绑定配置的快照。
  final Map<String, String> prefs;

  final WorkProfilePrefWriter _writer;
}

/// 进程内唯一的作品级配置覆盖层登记处（见 [WorkProfileSession]）。
///
/// 多个作品同时「打开」时（阅读器开着又启动了游戏），**最近进入**的会话生效；任一持有者
/// 离开只撤掉自己那一层。读侧（`PreferencesRepository` / `MediaSource` / `ReaderSettings` /
/// 本机查词）在没有会话时与引入覆盖层之前逐字节一致。
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

  /// 阅读器命名空间里**不**随作品走的键：字体目录与各用途字体表同时决定 App 界面 /
  /// 词典 / 视频字幕等全局表面的字体，进覆盖层就等于打开一本书换掉整个 App 的字体。
  static final Set<String> _readerGlobalKeys = <String>{
    for (final String short in const <String>[
      'font_catalog',
      'font_targets',
      'custom_fonts',
      'app_ui_fonts',
      'dict_fonts',
      'video_sub_fonts',
      'game_lookup_fonts',
      'floating_lyric_fonts',
      'srs_card_fonts',
    ])
      '$_readerPrefix$short',
  };

  /// [key]（`preferences` 表键）是否作品级键：会话期间读写都走覆盖层。
  static bool isWorkScopedPrefKey(String key) {
    if (ProfileKeys.isExcludedPref(key)) return false;
    if (key.startsWith(_readerPrefix)) return !_readerGlobalKeys.contains(key);
    return key.startsWith('floating_lyric_') &&
        key != kFloatingLyricWindowRectPrefKey;
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
    if (hadSession) notifyListeners();
  }
}
