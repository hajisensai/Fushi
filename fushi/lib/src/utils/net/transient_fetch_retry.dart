import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart' show NetworkImageLoadException;
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show HttpExceptionWithStatus;
import 'package:http/http.dart' as http;

/// 封面取图的自动退避梯度；**长度即最大自动重试次数**（BUG-2450）。
///
/// 封面是一屏几十张同时在跑的小请求，梯度比 mokuro 卷下载队列（2s/8s/20s）短：
/// 首次 1s 兜抖动/瞬断，后面拉长到 3s/8s 给站点过载留喘息。总计约 12s，超过还
/// 失败就交给失败态上的手动重试入口，继续机械重试对漫画源没有礼貌。
const List<Duration> kCoverFetchRetryBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 8),
];

/// 退避等待的注入口：生产走 [Future.delayed]，测试用记录器断言「只按退避表等待」。
typedef RetryWait = Future<void> Function(Duration delay);

Future<void> retryWaitReal(Duration delay) => Future<void>.delayed(delay);

/// 只有瞬时故障才值得自动重试：超时、socket/连接层错误、5xx。
///
/// 4xx 是资源本身的问题（404 不会因为多试两次就出现），Cloudflare 挑战要用户
/// 亲自过验证——这两类重试只会浪费退避时间、把失败态往后推十几秒。
bool isTransientNetworkError(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException) {
    return true;
  }
  if (error is NetworkImageLoadException) return error.statusCode >= 500;
  // 先于父类 HttpException 判：4xx 带状态码的必须落到「不重试」。
  if (error is HttpExceptionWithStatus) return error.statusCode >= 500;
  return error is HttpException;
}

/// 按 [backoff] 逐级退避重跑 [attempt]，直到成功、错误不可重试或梯度耗尽。
///
/// [stillWanted] 在每次等待前后各复查一次：排队/退避期间调用方整批退场时
/// 直接把最后一次错误抛回去，不再对漫画源发下一枪。
Future<T> retryTransient<T>(
  Future<T> Function() attempt, {
  List<Duration> backoff = kCoverFetchRetryBackoff,
  bool Function(Object error) shouldRetry = isTransientNetworkError,
  bool Function()? stillWanted,
  RetryWait wait = retryWaitReal,
}) async {
  for (int attemptIndex = 0;; attemptIndex++) {
    try {
      return await attempt();
    } on Object catch (error) {
      if (attemptIndex >= backoff.length || !shouldRetry(error)) rethrow;
      if (stillWanted != null && !stillWanted()) rethrow;
      await wait(backoff[attemptIndex]);
      if (stillWanted != null && !stillWanted()) rethrow;
    }
  }
}
