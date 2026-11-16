import 'dart:async';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart'
    show LeaderboardApiException;

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
/// - **隐私选项必须显式给**：附不附日志、附不附设备信息没有默认值，确认卡片上一定
///   看得到这两项的取值（模型不能靠省略参数悄悄带上日志）；
/// - **回执 ticket 不出路由**：ticket 是这条反馈的凭据（凭它看详情、追加说明），只回
///   反馈 id 与附件结果，不交给模型。
///
/// 截图 / 视频 / 联系方式 / 重新提交不经这条路由：模型拿不到截图，联系方式是用户的
/// 个人信息，重新提交要在反馈中心对着原反馈点；都留给反馈中心自己的界面。
List<CtlRoute> buildFeedbackCtlRoutes(OpContext context) =>
    buildFeedbackCtlRoutesFor(
      submit: (FeedbackDraft draft) =>
          context.ref.read(feedbackServiceProvider).submit(draft),
    );

/// 路由根。
const String kFeedbackCtlRoot = '/api/admin/feedback';

/// 路由表本体：提交函数按回调注入，测试不必起 [OpContext] / 真服务。
List<CtlRoute> buildFeedbackCtlRoutesFor({
  required Future<FeedbackSubmitResult> Function(FeedbackDraft draft) submit,
  String Function() newSubmissionKey = newFeedbackSubmissionKey,
}) => <CtlRoute>[
  CtlRoute.post(kFeedbackCtlRoot, (CtlCall call) async {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.rejected('提交反馈会把内容发给开发者、无法撤回，需要用户确认（confirm）');
    }
    final FeedbackDraft draft = feedbackDraftFromCall(
      call,
      submissionKey: newSubmissionKey(),
    );
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
    } on SocketException catch (e) {
      throw CtlFailure(502, 'upstream_failed', '连不上反馈服务：${e.message}');
    }
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
FeedbackDraft feedbackDraftFromCall(
  CtlCall call, {
  required String submissionKey,
}) {
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
  return FeedbackDraft(
    category: category,
    title: title,
    body: body,
    includeLogs: includeLogs,
    includeDeviceInfo: includeDeviceInfo,
    linkAccount: call.optBool('linkAccount') ?? true,
    submissionKey: submissionKey,
  );
}
