import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart'
    show redactAppNativeProxySecrets;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视频 / 查词性能诊断日志（用户 2026-09-22：「视频模块加入日志用于分析视频为什么
/// 卡顿、查词为什么卡；小内存模式可以解决但小内存会查词很慢会闪；日志尽量全一点跟
/// mpv 一样」）。
///
/// ## 为什么要单独一套
///
/// 现有三套日志都答不了这两个问题：[ErrorLogService] 只收错误（成功路径完全不可
/// 观测）、[DebugLogService] 只是 `debugPrint` 的内存拦截（无级别、无落盘、500 条
/// 就滚没了，一秒几十帧的采样撑不住）、`StudyDiagLog` 是统计域的事件流水（节奏是
/// 每次翻页几行，不是每秒上百行）。而「卡顿」与「查词慢」是**时序问题**：必须把
/// libmpv 的丢帧/迟帧、Flutter 的 build/raster 耗时、查词各阶段的毫秒数放在**同一
/// 条时间轴**上对齐，才看得出是谁拖了谁。
///
/// ## 与 mpv 的对齐
///
/// 行格式、级别名、级别过滤三样都照搬 libmpv，便于和 mpv 自己的 `--log-file` 对照
/// 阅读（诊断开启时两份日志同时产出，见 [mpvLogFileName]）：
///
/// ```
/// 2026-09-22 14:03:11.234 [  12.345][v][lookup] begin term=辞書 warm=hit
/// ```
///
/// * `[  12.345]` = 进程启动以来的秒数（mpv log-file 的第一列，对齐到 3 位小数）；
/// * `[v]` = 级别名，取值与 mpv `mp_log_levels` 同名同序：
///   `fatal error warn info status v debug trace`（[VideoDiagLevel]）；
/// * `[lookup]` = 类别（mpv 那列是 `cplayer` / `vo/gpu` 这样的模块前缀），本类的
///   类别表见 [VideoDiagCategory]；转写自 libmpv 的行原样带上 mpv 自己的前缀，
///   形如 `[mpv/vo/gpu]`。
///
/// 过滤走 [msgLevel]，语法与 mpv `--msg-level` 一致：`all=v,mpv=debug,frame=trace`。
/// 未列出的类别落到 `all`，`all` 缺省为 [VideoDiagLevel.v]（等价 mpv `-v`）。
///
/// ## 门控
///
/// 默认**关闭**（[enabled]，偏好键 [enabledPrefKey]，与 `debug_log_enabled` 同族
/// 走裸 SharedPreferences——诊断开关不进 Profile 快照，也要能在 `AppModel` 起来前
/// 读到）。关闭时 [add] 第一行就 `return`，零成本；逐帧探针与 mpv verbose 日志都
/// 只在开着时才接线。这和 mpv 要显式给 `--log-file` 是同一套约定：诊断是复现期才
/// 打开的东西，不是常驻开销。
class VideoDiagLog {
  VideoDiagLog._();

  static final VideoDiagLog instance = VideoDiagLog._();

  /// 开关偏好键（裸 SharedPreferences，对齐 `debug_log_enabled`）。
  static const String enabledPrefKey = 'video_diag_log_enabled';

  /// 级别过滤偏好键，值即 mpv `--msg-level` 语法的字符串。
  static const String msgLevelPrefKey = 'video_diag_log_msg_level';

  /// Dart 侧统一时间轴的文件名（应用文档目录根下，不新建子目录）。
  static const String fileName = 'video_diag_log.txt';

  /// libmpv 自己的 `--log-file` 落点：诊断开启时由 [VideoPlayerController] 把
  /// `log-file` / `msg-level` 下发给 libmpv，产出的是**货真价实的 mpv 日志**
  /// （VO / 交换链 / hwdec 协商 / 解码器 / demuxer 全在里面）。导出时一并带上。
  static const String mpvLogFileName = 'video_mpv_log.txt';

  /// 内存环上限。按 mpv 级别的啰嗦程度取（1 秒 1 行属性采样 + 1 秒 1 行帧汇总 +
  /// 查词每次十余行，12000 行够覆盖约半小时连续播放）。
  static const int maxEntries = 12000;

  /// 单文件上限（超出保尾并对齐行首）。Dart 侧时间轴比 mpv 原始日志密度低，4 MB
  /// 约合数小时。
  static const int maxFileBytes = 4 * 1024 * 1024;

  /// mpv 原始日志的保尾上限（verbose 下增长远快于 Dart 侧，单独给一档）。
  static const int maxMpvFileBytes = 8 * 1024 * 1024;

  /// `all` 未显式给出时的缺省级别（等价 mpv `-v`）。
  static const VideoDiagLevel defaultLevel = VideoDiagLevel.v;

  /// 默认过滤串：整体 verbose，但 mpv 转写行压到 info——libmpv 的 verbose 行已经
  /// 单独落进 [mpvLogFileName]，没必要在统一时间轴里再全量重复一遍（只留 warn /
  /// error 这类值得和其它域对齐时刻的）。用户可在设置里改。
  static const String defaultMsgLevel = 'all=v,mpv=info';

  final List<String> _lines = <String>[];
  final Stopwatch _uptime = Stopwatch()..start();

  File? _file;
  Directory? _dir;
  Future<void> _chain = Future<void>.value();

  bool _enabled = false;
  Map<String, VideoDiagLevel> _levels = parseMsgLevel(defaultMsgLevel);
  String _msgLevelSpec = defaultMsgLevel;

  /// 诊断是否开着。关着时 [add] 直接返回，探针与 mpv verbose 也不接线。
  bool get enabled => _enabled;

  /// 当前过滤串（mpv `--msg-level` 语法）。
  String get msgLevel => _msgLevelSpec;

  /// 本次运行的内存流水（只读快照，最旧在前）。
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 在途落盘链（测试确定性 await）。
  Future<void> get pending => _chain;

  /// 进程启动以来的毫秒数（各探针用同一把尺，保证时间轴可对齐）。
  int get uptimeMs => _uptime.elapsedMilliseconds;

  /// libmpv `log-file` 应当写到的绝对路径；日志目录还没解析出来时返回 null
  /// （此时不给 libmpv 下发 `log-file`，而不是瞎猜一个路径）。
  String? get mpvLogFilePath {
    final Directory? dir = _dir;
    if (dir == null) return null;
    return '${dir.path}/$mpvLogFileName';
  }

  /// [directoryOverride] / [prefsOverride] 仅供测试；生产走
  /// [fushiTestDirectory] / 应用文档目录 + 真实 SharedPreferences。
  ///
  /// 失败**不抛**：诊断日志起不来绝不能拦住启动，退化成纯内存环即可。
  Future<void> init({
    Directory? directoryOverride,
    SharedPreferences? prefsOverride,
  }) async {
    try {
      final SharedPreferences prefs =
          prefsOverride ?? await SharedPreferences.getInstance();
      _enabled = prefs.getBool(enabledPrefKey) ?? false;
      applyMsgLevel(prefs.getString(msgLevelPrefKey) ?? defaultMsgLevel);
    } catch (e) {
      debugPrint('[VideoDiagLog] prefs read failed: $e');
    }
    try {
      final Directory dir =
          directoryOverride ??
          fushiTestDirectory('app-documents') ??
          await getApplicationDocumentsDirectory();
      _dir = dir;
      _file = File('${dir.path}/$fileName');
      await _trimFile();
    } catch (e) {
      debugPrint('[VideoDiagLog] init failed: $e');
    }
    if (_enabled) {
      add(
        VideoDiagCategory.session,
        VideoDiagLevel.info,
        'session start msg-level=$_msgLevelSpec',
      );
    }
  }

  /// 开 / 关诊断。关掉时**不清**已有流水（用户往往是「复现完了先关掉再导出」），
  /// 只停止继续记录。
  Future<void> setEnabled(
    bool value, {
    SharedPreferences? prefsOverride,
  }) async {
    if (_enabled == value) return;
    if (value) {
      _enabled = true;
      add(
        VideoDiagCategory.session,
        VideoDiagLevel.info,
        'diagnostics enabled msg-level=$_msgLevelSpec',
      );
    } else {
      add(
        VideoDiagCategory.session,
        VideoDiagLevel.info,
        'diagnostics disabled',
      );
      _enabled = false;
    }
    try {
      final SharedPreferences prefs =
          prefsOverride ?? await SharedPreferences.getInstance();
      await prefs.setBool(enabledPrefKey, value);
    } catch (e) {
      debugPrint('[VideoDiagLog] prefs write failed: $e');
    }
  }

  /// 应用一条 mpv `--msg-level` 语法的过滤串（非法片段忽略，绝不抛）。
  void applyMsgLevel(String spec) {
    _msgLevelSpec = spec;
    _levels = parseMsgLevel(spec);
  }

  /// 落盘并持久化过滤串。
  Future<void> setMsgLevel(
    String spec, {
    SharedPreferences? prefsOverride,
  }) async {
    applyMsgLevel(spec);
    try {
      final SharedPreferences prefs =
          prefsOverride ?? await SharedPreferences.getInstance();
      await prefs.setString(msgLevelPrefKey, spec);
    } catch (e) {
      debugPrint('[VideoDiagLog] prefs write failed: $e');
    }
  }

  /// 该类别该级别当前是否记录（供高频探针在**拼字符串之前**短路——verbose 下每帧
  /// 拼一条又被丢掉，探针本身就成了卡顿源）。
  bool isLoggable(String category, VideoDiagLevel level) {
    if (!_enabled) return false;
    return passesFilter(category, level, _levels);
  }

  /// 记一行。[category] 取 [VideoDiagCategory] 的常量，[level] 对齐 mpv 级别。
  void add(String category, VideoDiagLevel level, String message) {
    if (!isLoggable(category, level)) return;
    final String line = formatLine(
      at: DateTime.now(),
      uptimeMs: _uptime.elapsedMilliseconds,
      category: category,
      level: level,
      message: message,
    );
    _lines.add(line);
    if (_lines.length > maxEntries) _lines.removeAt(0);
    final File? file = _file;
    if (file == null) return;
    _chain = _chain.then((_) => _append(file, line)).catchError((Object e) {
      debugPrint('[VideoDiagLog] append failed: $e');
    });
  }

  /// 纯函数：一行的格式（测试与 [add] 共用）。多行消息压成一行（`⏎`）——流水一行
  /// 一事件才能 grep。
  static String formatLine({
    required DateTime at,
    required int uptimeMs,
    required String category,
    required VideoDiagLevel level,
    required String message,
  }) {
    final String wall = at.toIso8601String().replaceFirst('T', ' ');
    final String flat = message.replaceAll('\r', '').replaceAll('\n', '⏎');
    return '$wall ${formatUptime(uptimeMs)}[${level.name}][$category] $flat';
  }

  /// 纯函数：mpv log-file 的第一列——`[  12.345]`，秒数右对齐到 6 字符宽。
  static String formatUptime(int uptimeMs) {
    final int ms = uptimeMs < 0 ? 0 : uptimeMs;
    final String secs = (ms ~/ 1000).toString();
    final String frac = (ms % 1000).toString().padLeft(3, '0');
    return '[${secs.padLeft(6)}.$frac]';
  }

  /// 纯函数：解析 mpv `--msg-level` 语法（`all=v,mpv=debug`）。非法片段与未知级别
  /// 名整条忽略（mpv 自己会报错退出，诊断日志没必要为此失效）。
  static Map<String, VideoDiagLevel> parseMsgLevel(String spec) {
    final Map<String, VideoDiagLevel> out = <String, VideoDiagLevel>{};
    for (final String part in spec.split(',')) {
      final int eq = part.indexOf('=');
      if (eq <= 0) continue;
      final String key = part.substring(0, eq).trim();
      final String value = part.substring(eq + 1).trim().toLowerCase();
      if (key.isEmpty) continue;
      final VideoDiagLevel? level = levelByName(value);
      if (level == null) continue;
      out[key] = level;
    }
    return out;
  }

  /// 纯函数：mpv 级别名 → [VideoDiagLevel]，未知名字返回 null。mpv 的「整类关闭」
  /// 写法 `foo=no` 落到 [VideoDiagLevel.no]（index 0）：任何真实记录级别都比它大，
  /// 于是 [passesFilter] 恒假——不需要为关闭再开一条特例分支。
  static VideoDiagLevel? levelByName(String name) {
    for (final VideoDiagLevel l in VideoDiagLevel.values) {
      if (l.name == name) return l;
    }
    return null;
  }

  /// 纯函数：过滤判据。精确类别优先，其次按 `/` 逐段回退（mpv 的 `vo/gpu` 可被
  /// `vo=` 命中），最后落到 `all`，都没有则用 [defaultLevel]。
  static bool passesFilter(
    String category,
    VideoDiagLevel level,
    Map<String, VideoDiagLevel> levels,
  ) {
    VideoDiagLevel? threshold = levels[category];
    if (threshold == null) {
      String probe = category;
      while (threshold == null) {
        final int slash = probe.lastIndexOf('/');
        if (slash <= 0) break;
        probe = probe.substring(0, slash);
        threshold = levels[probe];
      }
    }
    threshold ??= levels['all'] ?? defaultLevel;
    // 级别枚举按「越靠前越严重」排列，故阈值的 index 越大越啰嗦。
    return level.index <= threshold.index;
  }

  Future<void> _append(File file, String line) async {
    await file.writeAsString('$line\n', mode: FileMode.append);
    if (await file.length() > maxFileBytes) await _trimFile();
  }

  Future<void> _trimFile() async {
    final File? file = _file;
    if (file == null || !await file.exists()) return;
    if (await file.length() <= maxFileBytes) return;
    final List<int> bytes = await file.readAsBytes();
    await file.writeAsString(trimTail(bytes, maxBytes: maxFileBytes));
  }

  /// 纯函数：保尾到 [maxBytes] 并对齐行首（第一段残行丢弃）。
  static String trimTail(List<int> bytes, {int maxBytes = maxFileBytes}) {
    if (bytes.length <= maxBytes) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    final String content = utf8.decode(
      bytes.sublist(bytes.length - maxBytes),
      allowMalformed: true,
    );
    final int nl = content.indexOf('\n');
    if (nl < 0 || nl + 1 >= content.length) return content;
    return content.substring(nl + 1);
  }

  /// 等在途落盘写完（导出 / 退出前）。
  Future<void> flush() => _chain;

  /// Dart 侧时间轴全文（含此前运行）；没文件就退回内存环。导出前过一遍
  /// [redactVideoDiagSecrets]。
  Future<String> readPersisted() async {
    await flush();
    final File? file = _file;
    try {
      if (file != null && await file.exists()) {
        return redactVideoDiagSecrets(
          utf8.decode(await file.readAsBytes(), allowMalformed: true),
        );
      }
    } catch (e) {
      debugPrint('[VideoDiagLog] read failed: $e');
    }
    return redactVideoDiagSecrets(_lines.join('\n'));
  }

  /// libmpv 自己那份日志的尾部（导出用）。没开诊断 / libmpv 没写过就是空串。
  Future<String> readMpvLogTail({int maxBytes = maxMpvFileBytes}) async {
    final String? path = mpvLogFilePath;
    if (path == null) return '';
    try {
      final File file = File(path);
      if (!await file.exists()) return '';
      // libmpv 自己写的日志**原样**含流 URL：`[cplayer] Playing: <完整 URL>`，
      // `all=v` 下 `[stream]` / `[ffmpeg]` 还会再印几次。Jellyfin / Emby / 飞牛
      // 的流 URL 自带 `&api_key=<token>`、中间没有本地中继；native 代理口令也在
      // `http-proxy` 选项值里。这份日志是给用户导出发给开发者的，必须脱敏。
      return redactVideoDiagSecrets(
        trimTail(await file.readAsBytes(), maxBytes: maxBytes),
      );
    } catch (e) {
      debugPrint('[VideoDiagLog] mpv log read failed: $e');
      return '';
    }
  }

  Future<void> clear() async {
    _lines.clear();
    await flush();
    try {
      await _file?.writeAsString('');
      final String? mpvPath = mpvLogFilePath;
      if (mpvPath != null) {
        final File mpv = File(mpvPath);
        if (await mpv.exists()) await mpv.writeAsString('');
      }
    } catch (e) {
      debugPrint('[VideoDiagLog] clear failed: $e');
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _lines.clear();
    _file = null;
    _dir = null;
    _enabled = false;
    _chain = Future<void>.value();
    applyMsgLevel(defaultMsgLevel);
  }

  @visibleForTesting
  void enableForTesting({String? msgLevel}) {
    _enabled = true;
    if (msgLevel != null) applyMsgLevel(msgLevel);
  }
}

/// 日志级别，名字与顺序对齐 libmpv 的 `mp_log_levels`（越靠前越严重）。[no] 只作
/// 过滤阈值用（`--msg-level foo=no`），不作为 [VideoDiagLog.add] 的实参。
enum VideoDiagLevel { no, fatal, error, warn, info, status, v, debug, trace }

/// 类别常量表。分类的依据是「排查时会单独调级别的最小单位」——卡顿看 `frame` +
/// `mpv/stats`，查词慢看 `lookup` + `popup`，小内存权衡看 `memory` + `warmslot`。
abstract final class VideoDiagCategory {
  /// 会话级（启动、开关、页面进出、环境快照）。
  static const String session = 'session';

  /// 视频页生命周期（load / 换集 / 首帧 / 退出）。
  static const String video = 'video';

  /// libmpv 转写行（实际类别是 `mpv/<mpv 自己的前缀>`，如 `mpv/vo/gpu`）。
  static const String mpv = 'mpv';

  /// libmpv 属性周期采样（丢帧 / 迟帧 / avsync / 缓存 / 码率，对齐 mpv stats.lua）。
  static const String mpvStats = 'mpv/stats';

  /// Flutter 帧耗时聚合（build / raster / jank）。
  static const String frame = 'frame';

  /// 查词全链路分阶段计时。
  static const String lookup = 'lookup';

  /// 弹窗 WebView 侧（建 / loadStop / 注入 / renderPopup / 翻可见）。
  static const String popup = 'popup';

  /// 常驻热槽生命周期（seed / 命中 / 冷建 / 复位 / 销毁）。
  static const String warmSlot = 'warmslot';

  /// 内存策略（小内存模式、imageCache 预算、词典三级缓存预算）。
  static const String memory = 'memory';
}

/// 埋点统一入口：`videoDiag(VideoDiagCategory.lookup, VideoDiagLevel.v, '...')`。
void videoDiag(String category, VideoDiagLevel level, String message) =>
    VideoDiagLog.instance.add(category, level, message);

/// 高频探针的短路判据：拼字符串之前先问一句。
bool videoDiagEnabledFor(String category, VideoDiagLevel level) =>
    VideoDiagLog.instance.isLoggable(category, level);

/// 导出前的脱敏（纯函数）：native 代理口令、URL 查询参数里的令牌 / 密码、
/// `Authorization` / `X-Emby-Token` 这类头、以及 `MediaBrowser … Token="…"` 属性。
/// 只抹值不抹键，host + path 原样保留——排障要看得出是哪台服务器的哪条流。
String redactVideoDiagSecrets(String text) {
  String out = redactAppNativeProxySecrets(text);
  out = out.replaceAllMapped(
    _kSecretQueryParam,
    (Match m) => '${m.group(1)}[redacted]',
  );
  out = out.replaceAllMapped(
    _kSecretHeader,
    (Match m) => '${m.group(1)}[redacted]',
  );
  out = out.replaceAllMapped(
    _kSecretTokenAttr,
    (Match m) => '${m.group(1)}[redacted]${m.group(2)}',
  );
  return out;
}

final RegExp _kSecretQueryParam = RegExp(
  r'([?&](?:api_key|apikey|token|access_token|auth|authorization|password|'
  r'passwd|pwd|x-emby-token|x-mediabrowser-token)=)[^&\s"<>]+',
  caseSensitive: false,
);

final RegExp _kSecretHeader = RegExp(
  r'((?:authorization|x-emby-token|x-mediabrowser-token|x-emby-authorization)'
  r'\s*[:=]\s*)[^\r\n]+',
  caseSensitive: false,
);

final RegExp _kSecretTokenAttr = RegExp(
  r'(\bToken=")[^"]*(")',
  caseSensitive: false,
);
