/// 在线漫画书架条目不可用的错误类型（[OnlineMangaUnavailable]）与 Cloudflare 挑战判型
/// （[mihonCloudflareChallenge]）。
///
/// 单独成文件是为了**不带 UI 依赖**：原先定义在 `online_manga_runtime_adapter.dart`，
/// 那份文件为判「能不能在 app 内登录」import 了登录页 widget；全源搜索的聚合执行层
/// （`manga_global_search_runner.dart`）只为认这两个类型，就得经 widget 文件
/// `mihon_cloudflare_action.dart` 转一道。这里只依赖运行时模型与错误文案归一。
library;

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';

/// 一条在线漫画书架条目**不可用**的原因。
///
/// 分类而不是一句 message：作品页要据此决定给哪种出路——源被禁用要引导去
/// 「来源」页启用，平台不支持要直说「这个源在本平台不可用」而不是让用户对着
/// 「加载失败 + 重试」按钮反复重试一个永远不会成功的操作。
enum OnlineMangaUnavailableReason {
  /// 扩展/包已卸载或被停用。
  sourceDisabled,

  /// 该运行时在本平台根本不存在（如 iOS 上的 Mihon、已移除的 Aidoku）。
  platformUnsupported,

  /// 运行时在，但这次调用失败了（网络、站点抽风、Cloudflare）。
  runtimeFailure,
}

class OnlineMangaUnavailable implements Exception {
  const OnlineMangaUnavailable(
    this.reason,
    this.message, {
    this.cause,
    this.stage,
    this.sourceLabel,
  });

  final OnlineMangaUnavailableReason reason;
  final String message;
  final Object? cause;

  /// 断在哪一步：`details` / `chapters` / `pages` / `cover`。
  ///
  /// BUG-1767 的教训：三个阶段共用一个 catch，桥接层对它们返回的 code 可能完全
  /// 一样，不记 stage 就分不出是拉详情、拉章节还是取页面失败。
  final String? stage;

  /// 出错时那个源的展示名，进诊断文本。
  final String? sourceLabel;

  /// 可复制诊断对话框用的全文。
  ///
  /// 必须带上运行时原生侧的堆栈（`MihonRuntimeException.diagnostics` 里的
  /// `PlatformException.details`）——那几 KB 堆栈不进页面正文，但排障只能靠它。
  String get diagnostics {
    final Object? nested = cause;
    final String detail = nested is MihonRuntimeException
        ? nested.diagnostics
        : (nested?.toString() ?? message);
    return <String>[
      'stage: ${stage ?? 'unknown'}',
      if (sourceLabel != null) 'source: $sourceLabel',
      'reason: ${reason.name}',
      '',
      detail,
    ].join('\n');
  }

  /// 给用户看的一句话（toast / 错误视图正文）。
  ///
  /// [message] 多数是包装时的 `'$error'` 原串（`SocketException: Failed host
  /// lookup ...`），原样保留给 [diagnostics] / 日志；展示一律走这里，经
  /// [describeOnlineSourceError] 归一。[message] 不是 [cause] 的原串时说明
  /// 包装方专门写了说明（如「对端还没下载这一章」），按文本归一而不是退回
  /// [cause]。
  String get userMessage {
    final Object? nested = cause;
    if (nested != null && message == '$nested') {
      return describeOnlineSourceError(nested);
    }
    return describeOnlineSourceErrorText(message);
  }

  @override
  String toString() => 'OnlineMangaUnavailable($reason): $message';
}

/// 从阶段 / 运行时异常的 cause 链里找出结构化的 Cloudflare 挑战（没有返回
/// null）。挑战的文案是 `CLOUDFLARE_CHALLENGE_REQUIRED`，按文案匹配不到，只能按
/// 类型认。
MihonCloudflareChallengeException? mihonCloudflareChallenge(Object? error) {
  final Set<Object> visited = <Object>{};
  while (error != null && visited.add(error)) {
    if (error is MihonCloudflareChallengeException) return error;
    error = switch (error) {
      OnlineMangaUnavailable(:final cause) => cause,
      MihonRuntimeException(:final cause) => cause,
      _ => null,
    };
  }
  return null;
}
