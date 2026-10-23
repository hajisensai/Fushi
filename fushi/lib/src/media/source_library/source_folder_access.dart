// iOS 常驻来源文件夹的安全作用域访问（BUG-3665，反馈 Tz04dfBf2f）。
//
// 问题：iOS 上「添加本地文件夹」走 file_picker 的 `getDirectoryPath()`，拿到的是沙盒
// 外的路径，却从没 `startAccessingSecurityScopedResource()`——`dart:io` 一个字节都读
// 不到，于是书 / 漫画 / 视频的常驻来源加上了却永远扫不出东西（BUG-2786 记过的同一个
// 根因；一次性导入那边已改成整卷拷贝，常驻来源要反复复扫、视频要原地播放，不能拷）。
//
// 方案（用户拍板方案 A）：选目录时在访问窗口内建一份**安全作用域书签**存进
// `media_sources.configJson`（键 `iosBookmark`，不改 schema），用前重新解析 + 激活。
//
// 🔴 持有策略：**app 生命周期内持有**，不是「用一次停一次」。
// - 视频来源是原地播放（videoPath 指向来源文件夹里的原文件），播放器、字幕 sidecar、
//   制卡裁剪、封面全都在扫描之后的任意时刻读这些路径；按「扫描窗口」停掉访问，这些
//   读取统统落空。Apple 允许长期持有安全作用域访问，代价只是一份内核资源，按来源
//   行数计（每个来源一份），远低于系统上限。
// - 配对释放：来源被删除（[SourceFolderAccess.release]，由 `removeSourceLibrary`
//   与一次性导入的临时行收尾调用）时 stop；进程退出时系统自动回收，无需处理。
// - 激活时机：app 启动（`AppModel.initialise` 调 [SourceFolderAccess.activateAllOnStartup]，
//   不阻塞启动）+ 扫描前 + 播放前懒激活（[SourceFolderAccess.ensureForPath]）。三处都
//   幂等：同一来源行只 start 一次（Dart 侧按来源 id 记账），原生侧按路径计数，
//   书 / 漫画 / 视频三个来源指向同一文件夹时互不影响。
//
// 只在 iOS 上做事；其它平台 [SourceFolderAccess.requiresBookmark] 为 false，所有方法
// no-op（Android 走全文件访问 + 真实路径，桌面本就是真实路径，macOS 的数据根书签另见
// `storage/macos_data_root_access.dart`，与这里无关）。

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';

/// 一次「选目录并建书签」的结果。
@immutable
class SourceFolderBookmarkPick {
  const SourceFolderBookmarkPick({required this.path, required this.bookmark});

  /// 用户选中的文件夹路径（沙盒外，未激活前 `dart:io` 读不了）。
  final String path;

  /// base64 编码的书签，原样存进 configJson。
  final String bookmark;
}

/// 书签激活成功后的结果。
@immutable
class SourceFolderGrant {
  const SourceFolderGrant({
    required this.path,
    required this.stale,
    this.refreshedBookmark,
  });

  /// 书签解析出的**当前**路径（文件夹被移动后会与登记的根不同）。
  final String path;

  /// 书签是否过期（系统要求重建）。
  final bool stale;

  /// [stale] 时原生在访问窗口内重建的新书签；重建失败为 null。
  final String? refreshedBookmark;
}

/// 原生侧报的失败（[code] 取 `RESOLVE_FAILED` / `ACCESS_DENIED` / `BOOKMARK_FAILED`
/// / `BUSY` / `NO_PRESENTER` / `UNAVAILABLE`）。
class SourceFolderAccessException implements Exception {
  const SourceFolderAccessException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'SourceFolderAccessException($code: $message)';
}

/// 原生书签能力的最小接口——测试注入 fake，生产走 [MethodChannelSourceFolderBookmarks]。
abstract interface class SourceFolderBookmarks {
  /// 弹系统目录选择器并为选中的文件夹建书签；取消返回 null。
  Future<SourceFolderBookmarkPick?> pickDirectoryBookmark();

  /// 解析书签并开始访问；失败抛 [SourceFolderAccessException]。
  Future<SourceFolderGrant> startAccessingBookmark(String bookmark);

  /// 停止访问 [path]（[startAccessingBookmark] 交回的路径）。
  Future<void> stopAccessingBookmark(String path);
}

/// `app.fushi.reader/saf` channel 上的 iOS 实现（原生见
/// `ios/Runner/FushiDirectoryImport.swift`）。
class MethodChannelSourceFolderBookmarks implements SourceFolderBookmarks {
  const MethodChannelSourceFolderBookmarks([MethodChannel? channel])
    : _channel = channel;

  final MethodChannel? _channel;

  MethodChannel get _ch => _channel ?? FushiChannels.saf;

  @override
  Future<SourceFolderBookmarkPick?> pickDirectoryBookmark() async {
    final Object? raw = await _invoke('pickDirectoryBookmark');
    if (raw == null) return null;
    if (raw is! Map<Object?, Object?> ||
        raw['path'] is! String ||
        raw['bookmark'] is! String ||
        (raw['bookmark'] as String).isEmpty) {
      throw const SourceFolderAccessException(
        'BOOKMARK_FAILED',
        'malformed pickDirectoryBookmark result',
      );
    }
    return SourceFolderBookmarkPick(
      path: raw['path'] as String,
      bookmark: raw['bookmark'] as String,
    );
  }

  @override
  Future<SourceFolderGrant> startAccessingBookmark(String bookmark) async {
    final Object? raw = await _invoke(
      'startAccessingBookmark',
      <String, Object?>{'bookmark': bookmark},
    );
    if (raw is! Map<Object?, Object?> || raw['path'] is! String) {
      throw const SourceFolderAccessException(
        'RESOLVE_FAILED',
        'malformed startAccessingBookmark result',
      );
    }
    final Object? refreshed = raw['refreshedBookmark'];
    return SourceFolderGrant(
      path: raw['path'] as String,
      stale: raw['stale'] == true,
      refreshedBookmark: refreshed is String && refreshed.isNotEmpty
          ? refreshed
          : null,
    );
  }

  @override
  Future<void> stopAccessingBookmark(String path) async {
    await _invoke('stopAccessingBookmark', <String, Object?>{'path': path});
  }

  Future<Object?> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      throw SourceFolderAccessException(e.code, e.message ?? e.code);
    } on MissingPluginException catch (e) {
      // 原生半边没注册 = 本构建里没有这条能力，不是用户取消。
      throw SourceFolderAccessException('UNAVAILABLE', '$e');
    }
  }
}

/// iOS 常驻来源文件夹访问的唯一入口（见文件头的持有策略）。
class SourceFolderAccess {
  SourceFolderAccess({
    required SourceFolderBookmarks bookmarks,
    required bool Function() requiresBookmark,
  }) : _bookmarks = bookmarks,
       _requiresBookmark = requiresBookmark;

  /// 生产实例：只在 iOS 上需要书签。
  static SourceFolderAccess instance = SourceFolderAccess(
    bookmarks: const MethodChannelSourceFolderBookmarks(),
    requiresBookmark: () =>
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
  );

  final SourceFolderBookmarks _bookmarks;
  final bool Function() _requiresBookmark;

  /// 已激活的来源：来源 id → 原生交回的路径（stop 时要用它）。
  final Map<int, String> _active = <int, String>{};

  /// 同一来源的并发激活合并成一次（启动激活与首次扫描可能撞在一起），否则会
  /// start 两次只记一次账，那份多出来的访问永远没人 stop。
  final Map<int, Future<String?>> _inflight = <int, Future<String?>>{};

  FushiDatabase? _db;
  Future<void>? _startup;

  /// 当前平台是否需要书签（仅 iOS）。
  bool get requiresBookmark => _requiresBookmark();

  /// 来源 [sourceId] 是否已在访问中（测试与诊断用）。
  bool isActive(int sourceId) => _active.containsKey(sourceId);

  /// 弹系统目录选择器并建书签。非 iOS 不应调用（返回 null）。
  Future<SourceFolderBookmarkPick?> pickFolder() async {
    if (!requiresBookmark) return null;
    return _bookmarks.pickDirectoryBookmark();
  }

  /// app 启动时为所有本地来源激活一次（不阻塞调用方）。重复调用只生效第一次。
  void activateAllOnStartup(FushiDatabase db) {
    if (!requiresBookmark) return;
    _db = db;
    _startup ??= _activateAll(db);
  }

  Future<void> _activateAll(FushiDatabase db) async {
    final List<MediaSourceRow> rows = await db.getAllMediaSources();
    for (final MediaSourceRow row in rows) {
      if (row.transport != 'local') continue;
      final String? error = await ensureSourceAccess(db, row);
      if (error != null) {
        // 不弹框：用户此刻未必在看来源页。扫描时同一原因会写进 lastScanError。
        debugPrint(
          '[source-folder-access] source ${row.id} '
          '(${row.rootPath}) not activated: $error',
        );
      }
    }
  }

  /// 确保本地来源 [source] 处于访问中。
  ///
  /// 返回 null = 可以读（或本平台根本不需要书签）；否则返回给用户看的失败原因
  /// （已本地化），调用方原样写进 lastScanError / 提示。书签过期时把原生重建的新
  /// 书签回写 configJson。
  Future<String?> ensureSourceAccess(FushiDatabase db, MediaSourceRow source) {
    if (!requiresBookmark || source.transport != 'local') {
      return Future<String?>.value();
    }
    if (_active.containsKey(source.id)) return Future<String?>.value();
    final Future<String?>? pending = _inflight[source.id];
    if (pending != null) return pending;
    // 块体回调：箭头体会把 `remove` 交回的 Future（就是 run 自己）当成返回值，
    // whenComplete 等它完成 = 自己等自己，永不完成。
    final Future<String?> run = _activate(db, source).whenComplete(() {
      _inflight.remove(source.id);
    });
    _inflight[source.id] = run;
    return run;
  }

  Future<String?> _activate(FushiDatabase db, MediaSourceRow source) async {
    final String? bookmark = sourceBookmarkFromConfig(source.configJson);
    if (bookmark == null) {
      // 修复之前在 iOS 上加的来源（只有路径、没有授权）：重新添加同一文件夹即可补上
      // 书签（来源页撞同根时会把新书签写回这一行）。
      return t.media_source_folder_access_missing;
    }
    final SourceFolderGrant grant;
    try {
      grant = await _bookmarks.startAccessingBookmark(bookmark);
    } on SourceFolderAccessException catch (e) {
      return t.media_source_folder_access_resolve_failed(reason: e.message);
    }
    if (!sameSourceFolderPath(grant.path, source.rootPath)) {
      // 文件夹被挪走了：书签跟着它走到了新位置，但库里的媒体路径全都挂在旧根下，
      // 拿新根去扫会把整库重导一遍。不替用户改根，停掉访问并说清楚。
      await _bookmarks.stopAccessingBookmark(grant.path);
      return t.media_source_folder_access_moved(path: grant.path);
    }
    _active[source.id] = grant.path;
    final String? refreshed = grant.refreshedBookmark;
    if (grant.stale && refreshed != null) {
      await db.updateMediaSourceConfigJson(
        source.id,
        configWithSourceBookmark(source.configJson, refreshed),
      );
    }
    return null;
  }

  /// 播放 / 读取 [path] 之前调用：等启动激活跑完，再确保 [path] 所在的本地来源处于
  /// 访问中。[path] 不在任何来源下（单独导入的文件）时什么都不做。
  Future<void> ensureForPath(String path) async {
    if (!requiresBookmark) return;
    final FushiDatabase? db = _db;
    if (db == null) return;
    await _startup;
    for (final MediaSourceRow row in await db.getAllMediaSources()) {
      if (row.transport != 'local' || _active.containsKey(row.id)) continue;
      if (!isPathUnderSourceFolder(path, row.rootPath)) continue;
      final String? error = await ensureSourceAccess(db, row);
      if (error != null) {
        debugPrint('[source-folder-access] cannot open $path: $error');
      }
    }
  }

  /// 停止来源 [sourceId] 的访问（删除来源 / 一次性导入收尾）。未激活时 no-op。
  Future<void> release(int sourceId) async {
    final Future<String?>? pending = _inflight[sourceId];
    if (pending != null) await pending;
    final String? path = _active.remove(sourceId);
    if (path == null) return;
    try {
      await _bookmarks.stopAccessingBookmark(path);
    } on SourceFolderAccessException catch (e) {
      debugPrint('[source-folder-access] stop failed for $path: $e');
    }
  }

  /// 来源 [sourceId] 的书签刚被替换（用户重新添加了同一文件夹）：丢掉旧的访问，
  /// 下次用时按新书签重新激活。
  Future<void> invalidate(int sourceId) => release(sourceId);
}

/// iOS 上同一文件夹会以 `/private/var/...` 与 `/var/...` 两种写法出现（`/var` 是
/// `/private/var` 的符号链接，选择器与书签解析给的写法不一定一致）。比较前统一去掉
/// `/private` 前缀并按来源根的规则归一化。
String _canonicalFolderPath(String path) {
  String norm = normalizeSourceRootPath(path, transport: 'local');
  if (norm.startsWith('/private/')) norm = norm.substring('/private'.length);
  return norm;
}

/// [a] 与 [b] 是否指同一个来源文件夹（见 [_canonicalFolderPath]）。
@visibleForTesting
bool sameSourceFolderPath(String a, String b) =>
    _canonicalFolderPath(a) == _canonicalFolderPath(b);

/// [path] 是否位于来源根 [root] 之内（含根本身）。
@visibleForTesting
bool isPathUnderSourceFolder(String path, String root) {
  final String p = _canonicalFolderPath(path);
  final String r = _canonicalFolderPath(root);
  if (p == r) return true;
  return p.startsWith(r.endsWith('/') ? r : '$r/');
}

/// 新来源行（或撞同根的已有行）要写入的 configJson 片段。
Value<String?> sourceConfigValueForBookmark(String? bookmark) =>
    bookmark == null
    ? const Value<String?>.absent()
    : Value<String?>(configWithSourceBookmark(null, bookmark));
