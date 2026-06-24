import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/startup/test_environment.dart';
import 'package:hibiki/src/utils/misc/frame_safe_notifier.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:path_provider/path_provider.dart';

class ErrorLogEntry {
  ErrorLogEntry({
    required this.timestamp,
    required this.source,
    required this.error,
    this.stackTrace,
  });
  final DateTime timestamp;
  final String source;
  final String error;
  final String? stackTrace;

  String format() {
    final buf = StringBuffer()
      ..writeln('[$timestamp] $source')
      ..writeln(error);
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      buf.writeln(stackTrace);
    }
    buf.writeln('─' * 60);
    return buf.toString();
  }
}

class ErrorLogService extends ChangeNotifier with FrameSafeNotifier {
  ErrorLogService._();
  static final instance = ErrorLogService._();

  static const int _maxEntries = 200;
  static const int _maxFileBytes = 512 * 1024;

  final List<ErrorLogEntry> _entries = [];
  List<ErrorLogEntry> get entries => List.unmodifiable(_entries);

  File? _logFile;
  String _persistedLog = '';

  /// 导入面包屑文件：在每本词典调 native FFI 前**同步**写入，返回后清空。
  /// native 硬崩溃（访问违例 / 栈溢出）会绕过 Dart try/catch 直接带崩进程，
  /// 异步日志缓冲来不及落盘；这个文件因为同步写入而能存活崩溃，下次启动
  /// 把残留内容折进错误日志，即可定位是哪本词典把进程带崩的。
  File? _breadcrumbFile;

  /// 查词面包屑文件（TODO-607 P0-2，**独立**于导入面包屑 [_breadcrumbFile]）：
  /// 在每次「查词弹窗栈层进出」（顶层查词 / 嵌套查词 push / 关栈裁层）时**同步**
  /// 写入当前栈深度 + 顶层词。嵌套查词触发的 native 进程级闪退（跨线程 teardown
  /// 竞态，文档推断同 603-B / BUG-344，待 dump 坐实）会绕过所有 Dart 错误捕获
  /// （`FlutterError.onError` / `runZonedGuarded` / `PlatformDispatcher.onError`），
  /// 异步日志缓冲来不及落盘；这个文件因为**同步**写入而能存活崩溃，下次启动折成
  /// [_foldLookupBreadcrumb] 的 `Lookup.crashRecovered`，记下「上次嵌套查词把进程
  /// 带崩 + 崩时第几层」。与导入面包屑分文件，互不覆盖。
  File? _lookupBreadcrumbFile;

  /// [directoryOverride] 仅供测试注入临时目录（端到端验面包屑恢复，不碰
  /// path_provider）；生产不传，走 [hibikiTestDirectory] / 应用文档目录。
  Future<void> init({Directory? directoryOverride}) async {
    final dir = directoryOverride ??
        hibikiTestDirectory('app-documents') ??
        await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/error_log.txt');
    _breadcrumbFile = File('${dir.path}/import_crash_breadcrumb.txt');
    _lookupBreadcrumbFile = File('${dir.path}/lookup_crash_breadcrumb.txt');
    try {
      if (await _logFile!.exists()) {
        var content = await _logFile!.readAsString();
        if (content.length > _maxFileBytes) {
          content = content.substring(content.length - _maxFileBytes);
          final firstSep = content.indexOf('─' * 60);
          if (firstSep != -1) {
            content = content.substring(firstSep + 60).trimLeft();
          }
          await _logFile!.writeAsString(content);
        }
        _persistedLog = content;
      }
    } catch (e) {
      debugPrint('[ErrorLogService] init failed: $e');
    }
    // 崩溃恢复：上次有面包屑残留 = 那本词典的 native 导入没返回就崩了。
    try {
      final String? culprit = readAndClearBreadcrumb(_breadcrumbFile!);
      if (culprit != null) {
        log('DictImport.crashRecovered',
            '上次词典导入疑似让 app 崩溃（native 进程级，Dart 无法捕获）：$culprit');
      }
    } catch (e) {
      debugPrint('[ErrorLogService] breadcrumb recovery failed: $e');
    }
    // 查词崩溃恢复（TODO-607 P0-2）：上次有**查词**面包屑残留 = 进程在某查词栈层
    // 活跃时（最高频是嵌套查词）没退出就 native 崩了。独立文件、独立分支，折成
    // `Lookup.crashRecovered`（日志 label，非 i18n key），记下崩时栈深度。
    try {
      final String? lookupCulprit =
          readAndClearBreadcrumb(_lookupBreadcrumbFile!);
      if (lookupCulprit != null) {
        log(
            'Lookup.crashRecovered',
            '上次查词疑似让 app 崩溃（native 进程级，Dart 无法捕获；嵌套查词最高频，'
                '文档推断同 603-B 跨线程 teardown 竞态，待 dump 坐实）：$lookupCulprit');
      }
    } catch (e) {
      debugPrint('[ErrorLogService] lookup breadcrumb recovery failed: $e');
    }
  }

  /// 在调用 native 词典导入 FFI 之前**同步**落盘一条面包屑。[detail] 应能唯一
  /// 标识本次导入（如词典文件名）。必须同步，否则进程在异步 flush 前就已崩溃。
  ///
  /// 写入内容带时间戳：用户「正常强杀」恰好命中某本 FFI 执行中时，下次启动会
  /// 把残留误报为崩溃（与真硬崩在文件层不可区分）；带上时间戳让人工读日志时
  /// 能判断这条残留有多旧，区分「刚导一半被杀」和「很久以前的残留」。
  void markImportStart(String detail) {
    try {
      _breadcrumbFile?.writeAsStringSync('[${DateTime.now()}] $detail',
          flush: true);
    } catch (e) {
      debugPrint('[ErrorLogService] markImportStart failed: $e');
    }
  }

  /// native 导入正常返回（成功或被捕获的失败）后清掉面包屑。
  void markImportEnd() {
    try {
      final f = _breadcrumbFile;
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('[ErrorLogService] markImportEnd failed: $e');
    }
  }

  /// TODO-607 P0-2：查词弹窗栈层进出时**同步**写一条查词面包屑（[_lookupBreadcrumbFile]）。
  /// [depth] 是当前**可见**查词栈深度（0=已无可见弹窗，1=顶层查词，>=2=嵌套查词第
  /// `depth` 层）；[topTerm] 是栈顶在查的词（可空）。必须同步落盘，否则进程在异步
  /// flush 前就已 native 崩溃。[depth]<=0 时改为清掉面包屑（栈已空，无活跃查词，
  /// 此后再崩与查词无关——避免把「正常关弹窗后很久的崩溃」误报成查词崩）。
  ///
  /// 由 [DictionaryPopupController] 的栈进出方法经注入回调驱动（三查词表面共用一份
  /// 栈原语，一处接通覆盖书内 / 视频 / 首页查词全部路径）。带时间戳：用户「正常强杀」
  /// 恰好命中查词活跃期时下次启动会把残留报为崩溃，时间戳让人工读日志能判断残留新旧。
  void markLookupStackDepth(int depth, {String? topTerm}) {
    if (depth <= 0) {
      clearLookupBreadcrumb();
      return;
    }
    try {
      final String term = (topTerm == null || topTerm.isEmpty) ? '?' : topTerm;
      _lookupBreadcrumbFile?.writeAsStringSync(
        '[${DateTime.now()}] 查词栈深度=$depth（>=2 为嵌套查词），栈顶词=「$term」',
        flush: true,
      );
    } catch (e) {
      debugPrint('[ErrorLogService] markLookupStackDepth failed: $e');
    }
  }

  /// 查词栈清空（所有弹窗关闭）后删掉查词面包屑——此后崩溃与查词无关。
  void clearLookupBreadcrumb() {
    try {
      final f = _lookupBreadcrumbFile;
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('[ErrorLogService] clearLookupBreadcrumb failed: $e');
    }
  }

  /// 读取并删除面包屑文件，返回其内容（空 / 不存在返回 null）。纯文件操作，
  /// 便于单测注入临时文件。
  @visibleForTesting
  static String? readAndClearBreadcrumb(File f) {
    if (!f.existsSync()) return null;
    String content;
    try {
      content = f.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
    try {
      f.deleteSync();
    } catch (_) {
      // 删不掉就留着，下次启动再试；不影响本次恢复。
    }
    return content.isEmpty ? null : content;
  }

  void log(String source, Object error, [StackTrace? stack]) {
    final entry = ErrorLogEntry(
      timestamp: DateTime.now(),
      source: source,
      error: error.toString(),
      stackTrace: stack?.toString(),
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    notifyListenersFrameSafe();
    _appendToFile(entry);
  }

  /// TODO-607 P0-1：致命级错误（`FlutterError.onError` / `runZonedGuarded` 的
  /// UncaughtZone / `PlatformDispatcher.onError`）的**同步**落盘版本。
  ///
  /// 致命错误后进程可能立刻被带崩（尤其 `PlatformDispatcher.onError` 接住的、
  /// 来自 platform/原生回调的异常），常规 [log] 的异步 `_appendToFile` 来不及把
  /// 缓冲 flush 到磁盘——错误日志页就空了。这里在内存登记之外，额外用
  /// `writeAsStringSync(flush:true)` **同步**把这条 entry 追加进日志文件（复用
  /// 导入/查词面包屑同一「同步落盘存活崩溃」范式），保证即便下一刻崩溃，这条致命
  /// 错误也已在磁盘上，下次启动能读到。同步 IO 仅在罕见的致命路径触发，不影响热路径。
  void logFatal(String source, Object error, [StackTrace? stack]) {
    final entry = ErrorLogEntry(
      timestamp: DateTime.now(),
      source: source,
      error: error.toString(),
      stackTrace: stack?.toString(),
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    notifyListenersFrameSafe();
    try {
      _logFile?.writeAsStringSync(entry.format(),
          mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('[ErrorLogService] logFatal sync append failed: $e');
    }
  }

  Future<void> _appendToFile(ErrorLogEntry entry) async {
    try {
      await _logFile?.writeAsString(entry.format(), mode: FileMode.append);
    } catch (e) {
      debugPrint('[ErrorLogService] append failed: $e');
    }
  }

  String getFullLog() {
    if (_entries.isEmpty && _persistedLog.isEmpty) return t.error_log_empty;
    final buf = StringBuffer();
    for (final e in _entries.reversed) {
      buf.write(e.format());
    }
    if (_persistedLog.isNotEmpty) {
      if (_entries.isNotEmpty) {
        buf.writeln('═' * 60);
        buf.writeln('▼ ${t.error_log_previous_run}');
        buf.writeln('═' * 60);
      }
      buf.write(_persistedLog);
    }
    return buf.toString();
  }

  Future<void> clear() async {
    _entries.clear();
    _persistedLog = '';
    notifyListenersFrameSafe();
    try {
      await _logFile?.writeAsString('');
    } catch (e) {
      debugPrint('[ErrorLogService] clear failed: $e');
    }
  }
}

/// TODO-607 P0-2：查词栈深度变化的顶层回调（tear-off 友好），转调
/// [ErrorLogService.instance.markLookupStackDepth]。各查词宿主把它注入
/// [DictionaryPopupController.onLookupStackDepthChanged]，让 controller 保持纯逻辑
/// （不直接依赖单例 / 文件 IO），同时一处接通查词崩溃面包屑覆盖所有查词表面。
void recordLookupStackDepth(int depth, String? topTerm) {
  ErrorLogService.instance.markLookupStackDepth(depth, topTerm: topTerm);
}

/// BUG-089：制卡失败的统一处理。在所有 `MineResult.error` 分支调用：
/// ① 把**完整诊断**（原始异常 + 栈）写进 [ErrorLogService]（错误日志页可查），
/// ② 返回给用户看的**简短 toast 文案**（带后端带回的简短原因，无原因则降级到
///    通用文案）。
///
/// 单一真相源：5 个调用点（dictionary_page_mixin / reader_hibiki_page /
/// floating_dict_page / video_hibiki_page / app_model）都走这里，避免「记日志 +
/// 文案」逻辑被复制 5 份后各自漂移。[outcome] 应满足 `result == MineResult.error`。
String logMineFailure(MineOutcome outcome) {
  ErrorLogService.instance.log(
    'Anki.mineEntry',
    outcome.error ?? outcome.errorDetail ?? 'unknown card export error',
    outcome.stackTrace,
  );
  // TODO-752a：失败已分类（errorCode 非空）时，用与 locale 无关的稳定码映射本地化
  // toast——绝不把后端带回的 errorDetail（可能含 socket/http 的英文/latin1 乱码原文）
  // 直接喂给用户。errorDetail/error 仍写进上面的诊断日志。未分类失败维持旧行为。
  final String? localized = localizeAnkiMineError(outcome.errorCode);
  if (localized != null) return localized;
  final String? detail = outcome.errorDetail;
  return detail != null && detail.isNotEmpty
      ? t.card_export_failed_detail(reason: detail)
      : t.card_export_failed;
}

/// TODO-752a：把 [MineOutcome.errorCode] 映射成本地化的制卡失败 toast 文案；
/// 未分类（[code] 为 null 或未知）返回 `null`，由调用方退回旧的 [errorDetail] 文案。
/// 与 [localizeAnkiFetchError] 共享同一组 [AnkiErrorCode] 网络分类。
String? localizeAnkiMineError(String? code) {
  switch (code) {
    case AnkiErrorCode.connectionRefused:
      return t.anki_error_connection_refused;
    case AnkiErrorCode.connectionTimeout:
      return t.anki_error_connection_timeout;
    case AnkiErrorCode.httpError:
      return t.anki_error_http;
    case AnkiErrorCode.connectionUnknown:
      return t.anki_error_connection_unknown;
    default:
      return null;
  }
}

/// 把一次制卡结果映射成「给用户看的消息 + 是否成功 + 是否应计入制卡统计」的单一真相。
///
/// 此前这套四分支 switch（success/duplicate/notConfigured/error）在 5 个调用点
/// （dictionary_page_mixin / reader_hibiki_page / video_hibiki_page /
/// floating_dict_page / app_model）各复制一份，新增 outcome 类型或改文案要改 5 处。
/// 收口于此后各调用点只决定**怎么展示**（toast / OSD）与**是否记账/返回 bool**。
///
/// - error 分支内调 [logMineFailure]（写日志 + 取简短文案，单一来源）。
/// - 成功消息所需的牌组名 [deckName] 由调用方仅在 `success` 时预先解析
///   （仅成功分支需要，避免给失败分支白白 `loadSettings`）。
/// - [overwrite]=true 表示这是「覆盖已有卡片」（update 路径，非新制）：成功消息用
///   `card_overwritten`、且 `record=false`（覆盖不计入制卡统计）。此前 reader/video/
///   mixin 的 update 方法各自复制一份与 mine 几乎相同的 switch（只差 card_overwritten
///   + 不记账），一并收口于此。
({String message, bool success, bool record}) describeMineOutcome(
  MineOutcome outcome, {
  String deckName = '',
  bool overwrite = false,
}) {
  switch (outcome.result) {
    case MineResult.success:
      // TODO-779：卡片已建好，但单词远程音频下载失败（非 200 / 网络异常）时，把
      // 失败原因（含 HTTP 码/URL）追加到成功 toast，终结用户「没音频不知为何」的盲猜。
      // audioWarning 为 null（音频本就没有或下载成功）时维持原成功文案（向后兼容）。
      final String? audioWarning = outcome.audioWarning;
      final String baseMessage = overwrite
          ? t.card_overwritten(deck: deckName)
          : t.card_exported(deck: deckName);
      final String message = audioWarning != null && audioWarning.isNotEmpty
          ? '$baseMessage ${t.card_exported_audio_failed(reason: audioWarning)}'
          : baseMessage;
      return (
        message: message,
        success: true,
        // 覆盖已有卡片不是新制一张，不计入制卡统计（与新制路径区分）。
        record: !overwrite,
      );
    case MineResult.duplicate:
      return (message: t.card_duplicate, success: false, record: false);
    case MineResult.notConfigured:
      return (
        message: t.card_export_not_configured,
        success: false,
        record: false,
      );
    case MineResult.error:
      return (message: logMineFailure(outcome), success: false, record: false);
  }
}
