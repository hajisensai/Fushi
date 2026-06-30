import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 焦点驱动集成测试的「启动守卫」可复用层。
///
/// 解决两个反复出现的离屏 itest 摩擦点（见 TODO-947 排查）：
///
/// 1. **启动期网络调用冲红测试**：App 启动时 `UpdateChecker` 等会对 GitHub /
///    ghproxy 发请求，离线 / 证书过期环境下抛 `HandshakeException` /
///    `SocketException` / `CERTIFICATE_VERIFY_FAILED` 经 `FlutterError.onError`
///    冒泡，裸 itest 断言「无 FlutterError」会误判失败。这类纯网络层错误属环境
///    噪声，不是被测功能的缺陷，必须放行。
/// 2. **`FlutterError.onError` 未复原**：每个 itest 各自 `FlutterError.onError =`
///    捕获后若忘了在 `finally` 里还原，会污染同进程后续测试。这里统一在 `finally`
///    复原。
///
/// 用法（在 `app.main()` 之后跑被测主体）：
/// ```dart
/// import 'support/itest_startup_guard.dart';
///
/// void main() {
///   IntegrationTestWidgetsFlutterBinding.ensureInitialized();
///   testWidgets('xxx', (tester) async {
///     await runHibikiItest(label: 'shelf-organize', body: () async {
///       app.main();
///       expect(await waitForHome(tester), isTrue);
///       // ... 焦点驱动断言 ...
///     });
///   });
/// }
/// ```
///
/// 注意：本守卫**不**屏蔽 WebView/渲染器超时之外的真实错误——只放行明确的网络层
/// Handshake/Socket/证书类异常（与 `test_helpers.dart::assertStrictErrors` 同口径
/// 但更聚焦于启动期网络），其余 FlutterError 一律视为致命，断言失败。

/// 判定一条 [FlutterErrorDetails] 是否为「可放行的启动期网络噪声」。
///
/// 仅放行传输层 / TLS / 证书类异常（GitHub 更新检查在离线或证书过期环境下的
/// 必然失败）。任何 widget / render / 断言 / 状态错误都不在此列，保持致命。
bool isBenignStartupNetworkError(FlutterErrorDetails details) {
  final String msg = details.exceptionAsString().toLowerCase();
  return msg.contains('socketexception') ||
      msg.contains('handshakeexception') ||
      msg.contains('tlsexception') ||
      msg.contains('certificate_verify_failed') ||
      msg.contains('certificate has expired') ||
      msg.contains('httpexception') ||
      msg.contains('clientexception');
}

/// 把捕获到的 FlutterError 过滤掉启动期网络噪声后，断言剩余为空。
///
/// 暴露为独立函数，便于 itest 主体跑完后显式收口（也可由 [runHibikiItest]
/// 自动调用）。
void assertNoFatalStartupErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> fatal =
      errors.where((e) => !isBenignStartupNetworkError(e)).toList();
  expect(
    fatal,
    isEmpty,
    reason: 'Fatal FlutterError(s) after filtering benign startup-network noise: '
        '${fatal.map((e) => e.exceptionAsString()).join('; ')}',
  );
}

/// 包装一个焦点驱动 itest 主体：
///
/// - 安装 [FlutterError.onError] 收集器（网络噪声只记录不致命，其余记录待收口断言）；
/// - 跑 [body]；
/// - 在 `finally` 里**无条件复原** `FlutterError.onError`（避免污染同进程后续测试）；
/// - body 正常结束后（未抛）自动调 [assertNoFatalStartupErrors] 收口；
/// - 若 [body] 自身抛出，原异常向上传播（不被守卫吞掉），但 `onError` 仍被复原。
///
/// [collectedErrors] 可选传入外部 list，便于 body 内自查捕获到了什么。
Future<void> runHibikiItest({
  required Future<void> Function() body,
  String label = 'itest',
  List<FlutterErrorDetails>? collectedErrors,
}) async {
  final List<FlutterErrorDetails> errors =
      collectedErrors ?? <FlutterErrorDetails>[];
  final FlutterExceptionHandler? oldHandler = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    errors.add(details);
    final bool benign = isBenignStartupNetworkError(details);
    debugPrint('[$label] FlutterError'
        '${benign ? ' (benign startup-network, ignored)' : ''}: '
        '${details.exceptionAsString()}');
  };

  bool bodyThrew = false;
  try {
    await body();
  } catch (_) {
    bodyThrew = true;
    rethrow;
  } finally {
    FlutterError.onError = oldHandler;
    // 只有 body 正常结束才做「无致命错误」收口断言；body 已抛时让原异常优先暴露，
    // 不用守卫断言盖掉真正的失败原因。
    if (!bodyThrew) {
      assertNoFatalStartupErrors(errors);
    }
  }
}
