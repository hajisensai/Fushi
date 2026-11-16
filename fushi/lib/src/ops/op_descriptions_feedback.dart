import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_describe_kit.dart';

/// 应用内反馈的操作描述（spec §4；路由在 `ctl_feedback_routes.dart`）。
///
/// 撤销口径：提交 = 把标题 / 正文（与用户选了的日志、设备信息）发给开发者的反馈服务，
/// 是「把数据发给已指派 LLM 以外的第三方」（spec §5.2），服务端没有撤回接口，所以是
/// irreversible：AI 执行前出确认卡片（卡片列出全部参数，工具条目的详情里能看到完整
/// 正文），用户点了才注入 `confirm`。
///
/// 附日志 / 附设备信息 / 以账户身份提交三项是必填参数：确认卡片只列模型给出的参数，
/// 必填才能保证用户在点「执行」之前看得到要不要带日志、开发者会不会看到昵称。
List<OpDescription> describeFeedbackOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'feedback.submit',
    method: 'POST',
    pattern: '/api/admin/feedback',
    summary:
        'Submit in-app feedback to the Fushi developers on the user\'s behalf '
        '(bug report / suggestion), same as Feedback center › Submit. Only '
        'when the user asks to report something. Write the title and body from '
        'what the user said (in their language); do not include unrelated '
        'conversation content or credentials. Sending cannot be undone, so the '
        'user confirms first. Returns the feedback id; progress and replies '
        'are in the Feedback center.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'category',
        description: 'bug, suggestion or other.',
        required: true,
        enumValues: <String>['bug', 'suggestion', 'other'],
      ),
      OpParam.string(
        'title',
        description: 'One-line summary (max 120 characters).',
        required: true,
      ),
      OpParam.string(
        'body',
        description:
            'Details: what happened, steps to reproduce, expected result '
            '(max 8000 characters).',
      ),
      OpParam.boolean(
        'includeLogs',
        description:
            'Attach the app error / debug log (helps diagnose bugs; may '
            'contain file names and titles from the library). Ask the user '
            'if unsure.',
        required: true,
      ),
      OpParam.boolean(
        'includeDeviceInfo',
        description: 'Attach app version, platform, OS version and locale.',
        required: true,
      ),
      OpParam.boolean(
        'linkAccount',
        description:
            'When signed in to a Fushi account, submit under it so the '
            'developers see the nickname. Ask the user if unsure.',
        required: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed sending this feedback to the developers.',
      ),
    ],
  ),
];
