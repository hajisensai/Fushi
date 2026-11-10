/// 调试版流水线数据的拉取（更新中心「应用新版」域的流水线面板用）。
///
/// 数据是 CI 算好的一份 JSON（见 `docs/specs/2026-11-10-debug-pulse.md`），这里只负责拿到它：
/// 进程内记住上一份结果，面板再打开时先显示旧的、后台换新（数据本身分钟级变化，
/// 不值得落库）。
library;

import 'dart:io';

import 'package:fushi/src/utils/misc/update_checker.dart'
    show fetchDebugPulseBody;
import 'package:fushi_engine/updates/debug_pulse.dart';

/// 开发预览口：`--dart-define=FUSHI_DEBUG_PULSE_URL=<本地文件路径>` 时从本地文件读，
/// 用于在 CI 还没产出数据（或要看某份生成器输出）时预览面板。生产构建恒为空。
const String _kDebugPulseOverride = String.fromEnvironment(
  'FUSHI_DEBUG_PULSE_URL',
);

class DebugPulseService {
  DebugPulseService({Future<String?> Function()? fetchBody})
    : _fetchBody = fetchBody;

  final Future<String?> Function()? _fetchBody;

  /// 进程级共享实例。
  static final DebugPulseService instance = DebugPulseService();

  DebugPulseReport? _last;
  Future<DebugPulseReport?>? _inFlight;

  /// 上一次成功拿到的数据（可能是几分钟前的）。
  DebugPulseReport? get cached => _last;

  /// 拉最新数据；失败返回 null 且保留 [cached]。并发调用合并成一次请求。
  Future<DebugPulseReport?> refresh({String customProxy = ''}) {
    return _inFlight ??= _load(customProxy).whenComplete(() {
      _inFlight = null;
    });
  }

  Future<DebugPulseReport?> _load(String customProxy) async {
    final String? body =
        await (_fetchBody?.call() ?? _defaultFetch(customProxy));
    if (body == null) return null;
    final DebugPulseReport? report = DebugPulseReport.tryParse(body);
    if (report != null) _last = report;
    return report;
  }

  static Future<String?> _defaultFetch(String customProxy) async {
    if (_kDebugPulseOverride.isNotEmpty) {
      final File file = File(_kDebugPulseOverride);
      return file.existsSync() ? file.readAsString() : null;
    }
    return fetchDebugPulseBody(customProxy: customProxy);
  }
}
