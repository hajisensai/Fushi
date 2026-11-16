import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart'
    show LeaderboardApiException;
import 'package:http/http.dart' as http;

import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 应用内反馈的控制通道路由：让 AI 助手（与 `fushi_cli feedback submit`）代用户提交
/// 一条反馈（拍板台 tjJVY6ep5G，维护者选 B）。
///
/// 提交调用反馈中心「提交」按钮背后的同一个方法（[FeedbackService.submit]），不另写
/// 业务逻辑：回执照常落进本机「我的反馈」清单，之后在反馈中心看进度、追加说明、
/// 补截图。路由本身只做三件事：
///
/// - **表态门**：没有 `confirm` 一律拒绝。反馈会发给开发者（已指派 LLM 以外的第三方），
///   交上去撤不回，所以操作描述标 irreversible——AI 执行前出确认卡片，用户点了才注入
///   `confirm`；CLI 是用户自己加 `--yes`；
/// - **隐私选项必须显式给**：附不附日志、附不附设备信息、以不以账户身份（昵称）提交
///   都没有默认值，确认卡片上一定看得到这三项的取值（模型不能靠省略参数悄悄带上日志
///   或暴露昵称）；
/// - **同内容重试同一把幂等键**（[FeedbackSubmissionKeys]）：超时后重发不会建出重复反馈；
/// - **回执 ticket 不出路由**：ticket 是这条反馈的凭据（凭它看详情、追加说明），只回
///   反馈 id 与附件结果，不交给模型。
///
/// 截图 / 视频 / 联系方式 / 重新提交不经这条路由：模型拿不到截图，联系方式是用户的
/// 个人信息，重新提交要在反馈中心对着原反馈点；都留给反馈中心自己的界面。
List<CtlRoute> buildFeedbackCtlRoutes(OpContext context) =>
    buildFeedbackCtlRoutesFor(
      submit: (FeedbackDraft draft) =>
          context.ref.read(feedbackServiceProvider).submit(draft),
      keys: _processSubmissionKeys,
    );

/// 路由根。
const String kFeedbackCtlRoot = '/api/admin/feedback';

/// 进程内共用的一份幂等键记录：路由表会被重复构建（操作目录、控制通道各建一次），
/// 键必须跨构建存活，否则重试换了新键。
final FeedbackSubmissionKeys _processSubmissionKeys = FeedbackSubmissionKeys();

/// 提交幂等键（BUG-3489 同一口径，对齐反馈中心提交页的 `_submissionKeyFor`）：同样的
/// 内容再提交一次 = 重试同一次提交，带同一把键。请求其实已经到了服务端、回执没收到
/// （超时 / 断网）时，模型重发或用户在确认卡片上再点一次，拿回的是同一条反馈，不会多出
/// 一条重复反馈。成功后清掉，之后同样内容再交就是一次新的提交。
class FeedbackSubmissionKeys {
  FeedbackSubmissionKeys({String Function() newKey = newFeedbackSubmissionKey})
    : _newKey = newKey;

  final String Function() _newKey;
  String? _key;
  String? _signature;

  /// 这份草稿该带的键：内容与上一次未成功的提交相同就沿用，否则换新。
  String keyFor(FeedbackDraft draft) {
    final String signature = _signatureOf(draft);
    final String? key = _key;
    if (key != null && signature == _signature) return key;
    _signature = signature;
    return _key = _newKey();
  }

  /// 提交成功：这把键用完了。
  void succeeded(FeedbackDraft draft) {
    if (_signatureOf(draft) != _signature) return;
    _key = null;
    _signature = null;
  }

  static String _signatureOf(FeedbackDraft draft) => jsonEncode(<Object?>[
    draft.category.wire,
    draft.title.trim(),
    draft.body.trim(),
    draft.includeLogs,
    draft.includeDeviceInfo,
    draft.linkAccount,
  ]);
}

/// 路由表本体：提交函数按回调注入，测试不必起 [OpContext] / 真服务。
List<CtlRoute> buildFeedbackCtlRoutesFor({
  required Future<FeedbackSubmitResult> Function(FeedbackDraft draft) submit,
  required FeedbackSubmissionKeys keys,
}) => <CtlRoute>[
  CtlRoute.post(kFeedbackCtlRoot, (CtlCall call) async {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.rejected('提交反馈会把内容发给开发者、无法撤回，需要用户确认（confirm）');
    }
    final FeedbackDraft parsed = feedbackDraftFromCall(call);
    final FeedbackDraft draft = parsed.withSubmissionKey(keys.keyFor(parsed));
    final FeedbackSubmitResult result;
    try {
      result = await submit(draft);
    } on LeaderboardApiException catch (e) {
      throw CtlFailure(
        502,
        'upstream_failed',
        '反馈服务拒绝了提交：${e.status} ${e.code}'
            '${e.detail == null ? '' : '（${e.detail}）'}',
      );
    } on TimeoutException catch (e) {
      throw CtlFailure(502, 'upstream_failed', '反馈服务超时：$e');
    } on http.ClientException catch (e) {
      // package:http 把连接失败（断网、DNS、TLS）都包成 ClientException。
      throw CtlFailure(502, 'upstream_failed', '连不上反馈服务：${e.message}');
    } on SocketException catch (e) {
      throw CtlFailure(502, 'upstream_failed', '连不上反馈服务：${e.message}');
    }
    keys.succeeded(draft);
    return <String, Object?>{
      'id': result.ticket.id,
      'title': result.ticket.title,
      'category': result.ticket.category.wire,
      'logsAttached': draft.includeLogs,
      'deviceInfoAttached': draft.includeDeviceInfo,
      // 正文已交上去、但没传上去的附件（日志）数：留在待传区，反馈中心详情页可重试。
      'failedAttachments': result.failedAttachments,
    };
  }),
];

/// 把一次调用的参数解析成 [FeedbackDraft]（参数校验与反馈中心提交页同一口径：只有
/// 标题必填；长度上限取 [FeedbackLimits]，超了直接报错而不是悄悄截断——确认卡片上
/// 用户看到的就是要发出去的全部内容）。
FeedbackDraft feedbackDraftFromCall(CtlCall call) {
  // optString 已 trim、空白视同缺失：只有空格的标题在这里就报 400，不会交给服务端。
  final String title = call.optString('title') ?? '';
  if (title.isEmpty) throw const CtlFailure.badRequest('title 缺失');
  if (title.length > FeedbackLimits.titleMax) {
    throw CtlFailure.badRequest('title 超过 ${FeedbackLimits.titleMax} 字');
  }
  final String body = call.optString('body') ?? '';
  if (body.length > FeedbackLimits.bodyMax) {
    throw CtlFailure.badRequest('body 超过 ${FeedbackLimits.bodyMax} 字');
  }
  final String rawCategory = call.requireString('category');
  final FeedbackCategory? category = FeedbackCategory.values
      .where((FeedbackCategory c) => c.wire == rawCategory)
      .firstOrNull;
  if (category == null) {
    throw CtlFailure.badRequest(
      'category 只认 ${FeedbackCategory.values.map((FeedbackCategory c) => c.wire).join(' / ')}：$rawCategory',
    );
  }
  final bool? includeLogs = call.optBool('includeLogs');
  if (includeLogs == null) {
    throw const CtlFailure.badRequest('includeLogs 必须显式给出（true / false）');
  }
  final bool? includeDeviceInfo = call.optBool('includeDeviceInfo');
  if (includeDeviceInfo == null) {
    throw const CtlFailure.badRequest('includeDeviceInfo 必须显式给出（true / false）');
  }
  final bool? linkAccount = call.optBool('linkAccount');
  if (linkAccount == null) {
    throw const CtlFailure.badRequest('linkAccount 必须显式给出（true / false）');
  }
  return FeedbackDraft(
    category: category,
    title: title,
    body: body,
    includeLogs: includeLogs,
    includeDeviceInfo: includeDeviceInfo,
    linkAccount: linkAccount,
  );
}

extension on FeedbackDraft {
  FeedbackDraft withSubmissionKey(String key) => FeedbackDraft(
    category: category,
    title: title,
    body: body,
    includeLogs: includeLogs,
    includeDeviceInfo: includeDeviceInfo,
    linkAccount: linkAccount,
    submissionKey: key,
  );
}
