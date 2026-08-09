/// 只读元数据请求的**传输层重试**（BUG-1272）。
///
/// 背景：刮削链路上一次请求 = 一次成败，没有任何容错。而真实用户链路（尤其挂
/// 代理 / TUN 的用户）建连本身就会成片丢：实测同一台机器直连 `api.bgm.tv` 20 次
/// 有 8 次 TCP SYN 没有回应，成功的请求 0.5~0.8s 就返回，失败的一律卡到内核重传
/// 放弃（Windows 约 21s）。**中间不存在「再多等一会儿就能成」的区间**，所以把超时
/// 调长毫无用处，只会让用户多盯着转圈；唯一有效的做法是快速失败后**换一条连接重
/// 试**——浏览器打开同一个站点之所以「正常」，正是因为它连接复用 + 失败自动重连，
/// 把同样的丢连接悄悄补掉了。
///
/// **只重试「没拿到 HTTP 响应」的失败**，这是本模块唯一的正确性前提：
/// `package:http` 对非 2xx **不抛异常**（状态码原样返回给调用方），因此在「发一次
/// 请求」这一层捕获到异常 ⟺ 传输失败（连接被丢 / 超时 / TLS 失败）。403、404、429
/// 这类**服务端已明确回话**的结果永远走不到这里，自然不会被重试——尤其 429，重试
/// 只会加重限流。调用方若要对状态码做重试，那是另一层的策略，不属于本模块。
///
/// 幂等性：调用方必须自行保证被包住的请求可安全重放。当前使用方全部是只读的
/// GET / 搜索 POST。**写操作（收藏、进度上报）不得直接套用本函数**。
library;

import 'dart:async';

/// 默认尝试次数（含首次）：3 次。
///
/// 按实测单次成功率约 65% 估算，3 次尝试把整体失败率压到 ~4%；再加次数收益迅速
/// 递减，而最坏等待线性变长，不划算。
const int kTransportMaxAttempts = 3;

/// 重试前的基础退避，第 n 次重试等 `backoff * n`。
///
/// 丢连接不是服务端过载，不需要长退避；退避主要是给瞬时链路抖动一个恢复窗口。
const Duration kTransportRetryBackoff = Duration(milliseconds: 400);

/// 反复执行 [send]，直到成功或用尽 [maxAttempts] 次尝试。
///
/// 全部失败时**原样抛出最后一次的异常与堆栈**（不包装、不改写），使调用方既有的
/// 异常映射与文案保持不变。[sleep] 供测试注入，避免真实等待。
///
/// [shouldGiveUp]：可选的「再试也没意义了」判据，除次数上限外的第二个停手条件。
/// 调用方用它接入**跨重试共享的总预算**（封面下载的
/// `CoverDownloadDeadline`，TODO-2341）：预算耗尽即整体失败，不再发起新的尝试。
/// 每次失败后、以及每次退避等待之后都会重新求值——退避本身也吃预算。不传则行为不变。
Future<T> runWithTransportRetry<T>(
  Future<T> Function() send, {
  int maxAttempts = kTransportMaxAttempts,
  Duration backoff = kTransportRetryBackoff,
  Future<void> Function(Duration delay)? sleep,
  bool Function()? shouldGiveUp,
}) async {
  assert(maxAttempts > 0, 'maxAttempts 必须为正');
  final Future<void> Function(Duration delay) delay =
      sleep ?? (Duration d) => Future<void>.delayed(d);
  final bool Function() giveUp = shouldGiveUp ?? () => false;

  for (int attempt = 1;; attempt++) {
    try {
      return await send();
    } catch (error, stack) {
      // 用尽次数或用尽预算：把最后一次失败原样交还调用方（含堆栈），不吞不换。
      if (attempt >= maxAttempts || giveUp()) {
        Error.throwWithStackTrace(error, stack);
      }
      await delay(backoff * attempt);
      // 退避期间预算也可能耗尽，此时同样不再发起新尝试。
      if (giveUp()) Error.throwWithStackTrace(error, stack);
    }
  }
}
