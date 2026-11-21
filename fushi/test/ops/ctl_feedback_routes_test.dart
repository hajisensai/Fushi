import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart'
    show LeaderboardApiException, LeaderboardTimeoutException;
import 'package:http/http.dart' as http;

import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/ops/ctl_feedback_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造操作目录时不应访问 ref');
}

Matcher _failure(int status, [String? code]) => throwsA(
  isA<CtlFailure>()
      .having((CtlFailure f) => f.status, 'status', status)
      .having((CtlFailure f) => f.code, 'code', code ?? anything),
);

/// 拍板台 tjJVY6ep5G（维护者选 B）：AI 助手能代用户提交应用内反馈。
void main() {
  late List<FeedbackDraft> submitted;
  late Exception? failWith;
  late DateTime? quotaResetAt;
  late List<CtlRoute> routes;

  setUp(() {
    submitted = <FeedbackDraft>[];
    failWith = null;
    quotaResetAt = null;
    int keys = 0;
    routes = buildFeedbackCtlRoutesFor(
      submit: (FeedbackDraft draft) async {
        submitted.add(draft);
        final Exception? failure = failWith;
        if (failure != null) throw failure;
        return FeedbackSubmitResult(
          FeedbackTicket(
            id: 'abcDEF1234',
            ticket: 'secret-ticket-value',
            title: draft.title,
            category: draft.category,
            createdAt: 1,
            status: FeedbackStatus.open,
            updatedAt: 1,
            seenAt: 1,
            body: draft.body,
          ),
          failedAttachments: draft.includeLogs ? 1 : 0,
          quotaResetAt: quotaResetAt,
        );
      },
      keys: FeedbackSubmissionKeys(newKey: () => 'key-${keys++}'),
    );
  });

  Future<Object?> post(Map<String, Object?> body) => routes.single.handler(
    CtlCall(method: 'POST', path: kFeedbackCtlRoot, body: body),
  );

  const Map<String, Object?> valid = <String, Object?>{
    'category': 'bug',
    'title': '  AI 助手没法反馈  ',
    'body': '接入 AI 时内置 AI 缺少反馈功能',
    'includeLogs': true,
    'includeDeviceInfo': false,
    'linkAccount': true,
    'confirm': true,
  };

  test('提交走反馈服务：草稿字段原样带上，回执 ticket 不出路由', () async {
    final Object? result = await post(valid);
    expect(submitted, hasLength(1));
    final FeedbackDraft draft = submitted.single;
    expect(draft.category, FeedbackCategory.bug);
    expect(draft.title, 'AI 助手没法反馈');
    expect(draft.body, '接入 AI 时内置 AI 缺少反馈功能');
    expect(draft.includeLogs, isTrue);
    expect(draft.includeDeviceInfo, isFalse);
    expect(draft.linkAccount, isTrue);
    expect(draft.contact, isEmpty);
    expect(draft.screenshots, isEmpty);
    expect(draft.reopenOf, isNull);
    expect(draft.submissionKey, 'key-0');
    expect(result, <String, Object?>{
      'id': 'abcDEF1234',
      'title': 'AI 助手没法反馈',
      'category': 'bug',
      'logsAttached': true,
      'deviceInfoAttached': false,
      'failedAttachments': 1,
      'uploadQuotaResetAt': null,
    });
    expect('$result', isNot(contains('secret-ticket-value')));
  });

  test('附件撞上每 IP 每天上传额度：回执带额度重置时刻（UTC ISO 8601，BUG-4797）', () async {
    quotaResetAt = DateTime.utc(2026, 11, 22);
    final Object? result = await post(valid);
    expect(
      (result! as Map<String, Object?>)['uploadQuotaResetAt'],
      '2026-11-22T00:00:00.000Z',
    );
  });

  test('超时后同内容重试带同一把幂等键（不建重复反馈，BUG-3489 同口径）', () async {
    // 请求已到服务端、回执没收到：路由报 upstream_failed，模型 / 用户再发一次。
    failWith = LeaderboardTimeoutException(
      'POST',
      '/v1/feedback',
      const Duration(seconds: 30),
    );
    await expectLater(post(valid), _failure(502, 'upstream_failed'));
    failWith = null;
    // 首尾空白不同也算同一份内容。
    await post(<String, Object?>{...valid, 'title': 'AI 助手没法反馈'});
    // 成功之后同样内容再交 = 一次新提交，换新键。
    await post(valid);
    expect(submitted.map((FeedbackDraft d) => d.submissionKey), <String>[
      'key-0',
      'key-0',
      'key-1',
    ]);
  });

  test('内容（含隐私开关）变了就换新键', () async {
    failWith = const LeaderboardApiException(503, 'unavailable');
    await expectLater(post(valid), _failure(502));
    await expectLater(
      post(<String, Object?>{...valid, 'includeLogs': false}),
      _failure(502),
    );
    await expectLater(
      post(<String, Object?>{...valid, 'body': '另一段'}),
      _failure(502),
    );
    expect(submitted.map((FeedbackDraft d) => d.submissionKey), <String>[
      'key-0',
      'key-1',
      'key-2',
    ]);
  });

  test('没有用户确认（confirm）一律拒绝，不调反馈服务', () async {
    final Map<String, Object?> body = <String, Object?>{...valid}
      ..remove('confirm');
    await expectLater(post(body), _failure(422, 'rejected'));
    await expectLater(
      post(<String, Object?>{...valid, 'confirm': false}),
      _failure(422, 'rejected'),
    );
    expect(submitted, isEmpty);
  });

  test('附日志 / 附设备信息 / 以账户身份提交必须显式给出', () async {
    for (final String key in <String>[
      'includeLogs',
      'includeDeviceInfo',
      'linkAccount',
    ]) {
      final Map<String, Object?> body = <String, Object?>{...valid}
        ..remove(key);
      await expectLater(post(body), _failure(400), reason: key);
    }
    expect(submitted, isEmpty);
  });

  test('标题必填、类别只认三种、超长报错而不是截断', () async {
    await expectLater(
      post(<String, Object?>{...valid, 'title': '   '}),
      _failure(400),
    );
    await expectLater(
      post(<String, Object?>{...valid, 'category': 'praise'}),
      _failure(400),
    );
    await expectLater(
      post(<String, Object?>{
        ...valid,
        'title': 'x' * (FeedbackLimits.titleMax + 1),
      }),
      _failure(400),
    );
    await expectLater(
      post(<String, Object?>{
        ...valid,
        'body': 'x' * (FeedbackLimits.bodyMax + 1),
      }),
      _failure(400),
    );
    expect(submitted, isEmpty);
    await post(
      <String, Object?>{
        ...valid,
        'category': 'suggestion',
        'linkAccount': false,
      }..remove('body'),
    );
    expect(submitted.single.category, FeedbackCategory.suggestion);
    expect(submitted.single.body, isEmpty);
    expect(submitted.single.linkAccount, isFalse);
  });

  test('反馈服务拒绝 / 断网报 upstream_failed', () async {
    failWith = const LeaderboardApiException(429, 'rate_limited');
    await expectLater(post(valid), _failure(502, 'upstream_failed'));
    // package:http 的真实断网口径是 ClientException（不是 SocketException）。
    failWith = http.ClientException(
      'Failed host lookup',
      Uri.parse('https://x'),
    );
    await expectLater(post(valid), _failure(502, 'upstream_failed'));
    failWith = const SocketException('offline');
    await expectLater(post(valid), _failure(502, 'upstream_failed'));
  });

  test('操作目录：feedback.submit 是 irreversible、要确认、隐私开关对模型必填', () {
    final OpContext context = OpContext(ref: _UnusedRef());
    final OpCatalog catalog = buildAppOpCatalog(
      context,
      buildDomainOpRoutes(context),
    );
    final FushiOp op = catalog['feedback.submit']!;
    expect(op.risk, OpRisk.irreversible);
    expect(op.spec.needsConfirmation, isTrue);
    expect(op.undo, isNull);
    final Map<String, Object?> schema = op.spec.modelSchema();
    final Map<String, Object?> props =
        schema['properties']! as Map<String, Object?>;
    expect(props.containsKey('confirm'), isFalse, reason: '表态参数不给模型看');
    expect(
      schema['required'],
      containsAll(<String>[
        'category',
        'title',
        'includeLogs',
        'includeDeviceInfo',
        'linkAccount',
      ]),
    );
  });
}
