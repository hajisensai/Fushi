// 反馈页面共用：状态 / 分类文案、状态徽标、错误转人话、时间线、图片压缩、入口。

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_center_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开反馈中心。[captureScreen] 时先截下当前画面（打开前截，截到的是用户正在看的
/// 页面），作为新反馈的默认截图。首页按钮与悬浮球共用这一个入口。
Future<void> openFeedbackCenter(
  BuildContext context, {
  bool captureScreen = true,
}) async {
  final Uint8List? shot = captureScreen
      ? await captureFeedbackScreenshot()
      : null;
  if (!context.mounted) return;
  await Navigator.push(
    context,
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => FeedbackCenterPage(initialScreenshot: shot),
    ),
  );
}

String feedbackStatusLabel(FeedbackStatus status) => switch (status) {
  FeedbackStatus.open => t.feedback_status_open,
  FeedbackStatus.inProgress => t.feedback_status_in_progress,
  FeedbackStatus.resolved => t.feedback_status_resolved,
  FeedbackStatus.wontFix => t.feedback_status_wont_fix,
  FeedbackStatus.duplicate => t.feedback_status_duplicate,
  FeedbackStatus.closed => t.feedback_status_closed,
};

String feedbackCategoryLabel(FeedbackCategory category) => switch (category) {
  FeedbackCategory.bug => t.feedback_category_bug,
  FeedbackCategory.suggestion => t.feedback_category_suggestion,
  FeedbackCategory.other => t.feedback_category_other,
};

IconData feedbackCategoryIcon(FeedbackCategory category) => switch (category) {
  FeedbackCategory.bug => FushiIcons.error,
  FeedbackCategory.suggestion => FushiIcons.lightbulb,
  FeedbackCategory.other => FushiIcons.forum,
};

/// 服务端 / 网络错误 → 一句人话（提交失败、刷新失败共用）。
String feedbackErrorReason(Object error) {
  if (error is LeaderboardApiException) {
    if (error.status == 409 && error.code == 'duplicate_feedback') {
      return t.feedback_error_duplicate;
    }
    if (error.status == 429) return t.feedback_error_rate_limited;
    if (error.status == 503 || error.status == 507) {
      return t.feedback_error_unavailable;
    }
    return error.code;
  }
  return t.feedback_error_network;
}

/// 显示用户文字前剥掉伪装字符（双向控制符 / 零宽字符，emoji 的 ZWJ 保留）。服务端
/// 提交时已剥过，这里是纵深防御：旧数据或绕过服务端的内容也不会在处理台里「看到的和
/// 实际的不一样」。
String feedbackSafeText(String s) => s.replaceAll(
  RegExp(
    '[\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\u00AD]',
  ),
  '',
);

String feedbackFlagLabel(FeedbackFlag flag) => switch (flag) {
  FeedbackInjectionFlag() => t.feedback_dev_flag_injection,
  FeedbackHiddenCharsFlag() => t.feedback_dev_flag_hidden_chars,
  FeedbackLinksFlag() => t.feedback_dev_flag_links,
  FeedbackDuplicateFlag(:final String ofId) => t.feedback_dev_flag_duplicate(
    id: ofId,
  ),
};

/// 风险标记徽标（开发者列表 / 详情）。不认识的标记不显示。
class FeedbackFlagChips extends StatelessWidget {
  const FeedbackFlagChips(this.flags, {super.key});

  final List<String> flags;

  @override
  Widget build(BuildContext context) {
    final List<FeedbackFlag> parsed = <FeedbackFlag>[
      for (final String raw in flags) ?FeedbackFlag.parse(raw),
    ];
    if (parsed.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: tokens.spacing.gap / 2,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (final FeedbackFlag f in parsed)
          DecoratedBox(
            key: ValueKey<String>('feedback-flag-${f.runtimeType}'),
            decoration: ShapeDecoration(
              color: colors.errorContainer,
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Text(
                feedbackFlagLabel(f),
                style: tokens.type.metadata.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String feedbackTime(int ms) =>
    FushiTimeFormat.dateHourMinute(DateTime.fromMillisecondsSinceEpoch(ms));

/// 状态徽标：未结案用强调色，已解决用成功色，其余中性。
class FeedbackStatusBadge extends StatelessWidget {
  const FeedbackStatusBadge(this.status, {super.key});

  final FeedbackStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final (Color bg, Color fg) = switch (status) {
      FeedbackStatus.open => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      FeedbackStatus.inProgress => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      FeedbackStatus.resolved => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      _ => (colors.outlineVariant, colors.onSurface),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Text(
          feedbackStatusLabel(status),
          style: tokens.type.metadata.copyWith(color: fg),
        ),
      ),
    );
  }
}

/// 处理记录时间线（反馈人与开发者两边的详情页共用）。
class FeedbackTimeline extends StatelessWidget {
  const FeedbackTimeline({required this.messages, super.key});

  final List<FeedbackMessage> messages;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (messages.isEmpty) {
      return Text(
        t.feedback_detail_no_messages,
        style: tokens.type.listSubtitle,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < messages.length; i++)
          FushiStaggeredEntrance(
            index: i,
            child: _FeedbackMessageTile(
              message: messages[i],
              tokens: tokens,
              colors: colors,
            ),
          ),
      ],
    );
  }
}

class _FeedbackMessageTile extends StatelessWidget {
  const _FeedbackMessageTile({
    required this.message,
    required this.tokens,
    required this.colors,
  });

  final FeedbackMessage message;
  final FushiDesignTokens tokens;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final FeedbackMessage m = message;
    final String who = m.fromDeveloper
        ? t.feedback_detail_developer(name: m.nickname ?? '')
        : t.feedback_detail_you;
    final FeedbackStatus? status = m.status;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              color: m.fromDeveloper ? colors.primary : colors.outlineVariant,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '$who · ${feedbackTime(m.createdAt)}',
                style: tokens.type.metadata,
              ),
              if (status != null)
                Text(
                  t.feedback_detail_status_changed(
                    status: feedbackStatusLabel(status),
                  ),
                  style: tokens.type.metadata.copyWith(color: colors.primary),
                ),
              if (m.body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SelectableText(feedbackSafeText(m.body)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用户选的图：小于服务端上限且是 PNG / JPEG / WebP 就原样用，否则缩到长边
/// [kFeedbackScreenshotMaxSide] 再存 JPEG。解码 / 编码在后台 isolate。不是图片抛
/// [FormatException]。
Future<Uint8List> prepareFeedbackImage(Uint8List bytes) =>
    Isolate.run<Uint8List>(() => prepareFeedbackImageBytes(bytes));

/// [prepareFeedbackImage] 的同步内核（纯函数，可单测）。
Uint8List prepareFeedbackImageBytes(Uint8List bytes) {
  final bool known =
      (bytes.length > 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff) ||
      (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50) ||
      (bytes.length > 12 &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP');
  if (known && bytes.length <= FeedbackLimits.screenshotMaxBytes) return bytes;
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    decoded = null;
  }
  if (decoded == null) throw const FormatException('not a decodable image');
  final int longest = math.max(decoded.width, decoded.height);
  img.Image out = decoded;
  if (longest > kFeedbackScreenshotMaxSide) {
    out = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: kFeedbackScreenshotMaxSide)
        : img.copyResize(decoded, height: kFeedbackScreenshotMaxSide);
  }
  int quality = 85;
  Uint8List jpg = img.encodeJpg(out, quality: quality);
  while (jpg.length > FeedbackLimits.screenshotMaxBytes && quality > 40) {
    quality -= 15;
    jpg = img.encodeJpg(out, quality: quality);
  }
  return jpg;
}

/// 反馈中心入口按钮上的未读数（有开发者新进展）。
int watchFeedbackUnseen(WidgetRef ref) => ref.watch(
  feedbackServiceProvider.select((FeedbackService s) => s.unseenCount),
);
