import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-1563：互联 host 侧两类「失败被吞」。
///
///  ① `FushiSyncServerController.start/restart/startIfEnabled` 返回的
///     [FushiServerStartOutcome] 只有开关那条路径认真读了；换令牌（restart）、开 TLS
///     （restart）、开页兜底启动（startIfEnabled）三处把返回值直接丢掉。restart 是先
///     stop 再 start，start 失败（端口被占 / TLS 证书加载失败）就等于用户点一下按钮把
///     自己的 host 关掉了，而 UI 仍显示「正在运行」，对端连不上且零提示。
///     开 TLS 失败时旧代码还照样弹「已配对设备需重新配对」——对着一台已经不存在的
///     host 给操作建议。
///  ② 「用互联做备份后端」只有 try/finally。`applyBackupBackendChange` 会连写多个偏好，
///     中途抛异常时库里已经半写、内存态还是旧值（UI 与库不一致），异常还逃逸成
///     unhandled zone error，用户零提示。
void main() {
  String serverWidgetSlice(String corpus) {
    final int start = corpus.indexOf('class _ServerModeWidgetState');
    expect(start, greaterThanOrEqualTo(0), reason: '服务器模式 widget 丢失');
    final int end = corpus.indexOf('class _LanDiscoveryWidget', start);
    expect(end, greaterThan(start));
    return corpus.substring(start, end);
  }

  test('① 存在唯一的 outcome 消费点，三种结局都有出口', () {
    final String corpus = readSyncSettingsSchemaSource();
    final String apply = methodBody(
      corpus,
      '  void _applyStartOutcome(FushiServerStartOutcome outcome)',
    );
    for (final String branch in <String>[
      'FushiServerStarted()',
      'FushiServerPortInUse(',
      'FushiServerStartError(',
    ]) {
      expect(containsCodeLine(apply, branch), isTrue,
          reason: '$branch 没有分支 = 这种失败仍然静默');
    }
    expect(containsIdentifierCall(apply, '_showSnackBar'), isTrue,
        reason: '失败必须上屏，只改内存态用户照样看不见');
    expect(containsCodeLine(apply, 'setServerEnabled(false)'), isTrue,
        reason: '启动失败后开关必须回落真实状态（host 并没有在跑）');
  });

  test('① host 的每个启动/重启调用点都消费 outcome，没有裸 await 丢弃', () {
    final String server = serverWidgetSlice(readSyncSettingsSchemaSource());
    final String masked = maskComments(server);
    // 「裸丢弃」的形态是**整条语句**就是一次 await 调用（行首起、以分号收），
    // `final ... = await _serverController.restart();` 这种把结果接住的写法不算。
    expect(
      RegExp(r'^\s*await\s+_serverController\.restart\(\)\s*;', multiLine: true)
          .hasMatch(masked),
      isFalse,
      reason: '裸 await restart() 丢掉返回值——重启失败时 host 已经停了却无人知晓',
    );
    expect(
      RegExp(r'^\s*await\s+_serverController\.startIfEnabled\(\)\s*;',
              multiLine: true)
          .hasMatch(masked),
      isFalse,
      reason: '裸 await startIfEnabled() 同理：开页兜底启动失败被静默吞掉',
    );
    // 三个调用点都得把结果喂进消费函数。
    final String regen =
        methodBody(server, '  Future<void> _regenerateToken()');
    expect(
      containsIdentifierCall(regen, '_applyStartOutcome'),
      isTrue,
      reason: '重新生成令牌 = 一次重启，失败必须说清楚',
    );
    final String tls =
        methodBody(server, '  Future<void> _setTlsEnabled(bool v)');
    expect(containsIdentifierCall(tls, '_applyStartOutcome'), isTrue);
    final int outcomeAt =
        maskComments(tls).indexOf('outcome is! FushiServerStarted');
    final int hintAt =
        maskComments(tls).indexOf('t.sync_server_tls_repair_hint');
    expect(outcomeAt, isNonNegative, reason: '开 TLS 失败必须与成功走不同出口');
    expect(outcomeAt, lessThan(hintAt),
        reason: '重启失败后不能再弹「需重新配对」——那台 host 已经不在了');
    final String load = methodBody(server, '  Future<void> _loadSettings()');
    expect(containsIdentifierCall(load, '_applyStartOutcome'), isTrue);
  });

  test('② 「设为备份后端」有 catch，失败时回库重读真值并上屏', () {
    final String corpus = readSyncSettingsSchemaSource();
    final String apply =
        methodBody(corpus, '  Future<void> _useInterconnectAsBackend()');
    final String masked = maskComments(apply);
    expect(masked.contains('} catch ('), isTrue,
        reason: '只有 try/finally = DB 半写时 UI 停在旧值，异常逃逸成 unhandled error');
    expect(containsCodeLine(apply, 'getBackendType()'), isTrue,
        reason: '失败后必须回 preferences 重读真实后端，让 UI 与库一致');
    expect(containsIdentifierCall(apply, '_showSnackBar'), isTrue,
        reason: '失败必须上屏');
    expect(containsCodeLine(apply, 'ErrorLogService.instance'), isTrue,
        reason: '失败要留日志，否则事后无从定位');
  });
}
