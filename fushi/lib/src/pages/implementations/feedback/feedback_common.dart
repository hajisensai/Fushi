// 反馈页面共用：状态 / 分类文案、状态徽标、错误转人话、时间线、图片压缩、入口。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_entry_gate.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_center_page.dart';
import 'package:fushi/src/utils/misc/clipboard_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开反馈中心。[captureScreen] 时先截下当前画面（打开前截，截到的是用户正在看的
/// 页面），作为新反馈的默认截图。首页按钮与悬浮球共用这一个入口。
///
/// 经 [feedbackEntryGate]：已经开着时忽略重复点击；有页面转场在跑时等它走完再截，
/// 不会截到两页叠在一起的中间帧（BUG-3097）。
Future<void> openFeedbackCenter(
  BuildContext context, {
  bool captureScreen = true,
}) => feedbackEntryGate.open(
  context,
  captureScreen: captureScreen,
  route: (Uint8List? shot) => adaptivePageRoute<void>(
    context: context,
    builder: (_) => FeedbackCenterPage(initialScreenshot: shot),
  ),
);

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
/// 反馈编号（服务端 id）：`#svSfwFdmdM` 等宽小字，点按或长按复制。
class FeedbackIdLabel extends StatelessWidget {
  const FeedbackIdLabel(this.id, {this.style, super.key});

  final String id;
  final TextStyle? style;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(t.feedback_id_copied)));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiTooltip(
      message: t.feedback_id_copy_hint,
      child: Semantics(
        button: true,
        label: '${t.feedback_id_copy_hint} $id',
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey<String>('feedback-id-$id'),
          borderRadius: FushiM3eShape.smallRadius,
          onTap: () => unawaited(_copy(context)),
          onLongPress: () => unawaited(_copy(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              '#$id',
              style: (style ?? tokens.type.metadata).copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页抬头那一行：分类 · #编号（可复制）· 提交时间。
class FeedbackMetaLine extends StatelessWidget {
  const FeedbackMetaLine(this.detail, {super.key});

  final FeedbackDetail detail;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = FushiDesignTokens.of(context).type.metadata;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '${feedbackCategoryLabel(detail.summary.category)} · ',
          style: style,
        ),
        FeedbackIdLabel(detail.id, style: style),
        Text(' · ${feedbackTime(detail.summary.createdAt)}', style: style),
      ],
    );
  }
}

/// 「重新提交」关联：新反馈上「重新提交自 #原编号」、原反馈上「已被重新提交为 #新编号」。
/// [onOpen] 给了就能点过去；[canOpen] 判某一条打不打得开（反馈人那边，别的设备提交的
/// 那条本机没有 ticket 看不了）。打不开的只显示成不可点的标签，不画成能点的 chip
/// （BUG-3243：以前画成 chip、点了没反应）。
class FeedbackRelationLinks extends StatelessWidget {
  const FeedbackRelationLinks({
    required this.parentId,
    required this.reopenedAs,
    this.onOpen,
    this.canOpen,
    super.key,
  });

  final String? parentId;
  final List<String> reopenedAs;
  final void Function(String id)? onOpen;

  /// null = 凡是给了 [onOpen] 都能打开。
  final bool Function(String id)? canOpen;

  @override
  Widget build(BuildContext context) {
    if (parentId == null && reopenedAs.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final void Function(String id)? open = onOpen;
    Widget link(String id, String label) =>
        open != null && (canOpen?.call(id) ?? true)
        ? FushiActionChip(
            key: ValueKey<String>('feedback-relation-$id'),
            icon: FushiIcons.link,
            label: label,
            onPressed: () => open(id),
          )
        : FushiTag(
            key: ValueKey<String>('feedback-relation-$id'),
            icon: FushiIcons.link,
            text: label,
            tone: FushiTagTone.neutral,
            dense: true,
          );
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        if (parentId != null)
          link(parentId!, t.feedback_reopen_of(id: parentId!)),
        for (final String id in reopenedAs)
          link(id, t.feedback_reopened_as(id: id)),
      ],
    );
  }
}

/// 「我的反馈」本机搜索：编号 / 标题 / 正文，统一归一化口径。
List<FeedbackTicket> filterFeedbackTickets(
  List<FeedbackTicket> tickets,
  String query,
) => filterByMediaSearch<FeedbackTicket>(
  tickets,
  query,
  (FeedbackTicket x) => <String>[x.id, x.title, x.body],
);

class FeedbackTimeline extends StatelessWidget {
  const FeedbackTimeline({
    required this.messages,
    this.developerView = false,
    super.key,
  });

  final List<FeedbackMessage> messages;

  /// 开发者处理页：反馈人的消息标「反馈人」而不是「你」。
  final bool developerView;

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
              developerView: developerView,
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
    required this.developerView,
    required this.tokens,
    required this.colors,
  });

  final FeedbackMessage message;
  final bool developerView;
  final FushiDesignTokens tokens;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final FeedbackMessage m = message;
    final String who = m.fromDeveloper
        ? t.feedback_detail_developer(name: m.nickname ?? '')
        : developerView
        ? t.feedback_dev_reporter
        : t.feedback_detail_you;
    final FeedbackStatus? status = m.status;
    // 反馈人在详情页点「标记为已完成」留下的事件。
    final bool reporterClosed =
        !m.fromDeveloper && status == FeedbackStatus.closed;
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
                  reporterClosed
                      ? (developerView
                            ? t.feedback_timeline_reporter_closed
                            : t.feedback_timeline_you_closed)
                      : t.feedback_detail_status_changed(
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

/// 从文件管理器复制的文件里，按扩展名认作图片的那些。
const Set<String> kFeedbackClipboardImageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
  '.gif',
};

/// 被复制的单个图片文件读取上限：再大就不是截图了，也不该整个读进内存。
const int kFeedbackClipboardFileMaxBytes = 64 * 1024 * 1024;

/// 从系统剪贴板取出可加入反馈的图片，最多 [limit] 张，每张已按反馈上限处理过
/// （[prepareFeedbackImage]：超限转 JPEG 缩小）。
///
/// 截图工具放进来的位图优先，其次是在文件管理器里复制的图片文件（按扩展名过滤，
/// 非图片文件跳过）。剪贴板里没有图片返回空表；读剪贴板本身失败照常抛出。单个文件
/// 读不了 / 解不出来只跳过那一个并记日志。
Future<List<Uint8List>> readFeedbackImagesFromClipboard({
  required int limit,
}) async {
  if (limit <= 0) return const <Uint8List>[];
  final ClipboardImageData? data = await readClipboardImage();
  if (data == null) return const <Uint8List>[];
  final List<Uint8List> raw = <Uint8List>[?data.bytes];
  for (final String path in data.paths) {
    if (raw.length >= limit) break;
    if (!kFeedbackClipboardImageExtensions.contains(
      p.extension(path).toLowerCase(),
    )) {
      continue;
    }
    try {
      final File file = File(path);
      if (await file.length() > kFeedbackClipboardFileMaxBytes) continue;
      raw.add(await file.readAsBytes());
    } on FileSystemException catch (e, st) {
      ErrorLogService.instance.log('feedback.paste_image_file', e, st);
    }
  }
  final List<Uint8List> out = <Uint8List>[];
  for (final Uint8List bytes in raw.take(limit)) {
    try {
      out.add(await prepareFeedbackImage(bytes));
    } on FormatException catch (e, st) {
      ErrorLogService.instance.log('feedback.paste_image_decode', e, st);
    }
  }
  return out;
}

/// 反馈中心入口按钮上的未读数（有开发者新进展）。
int watchFeedbackUnseen(WidgetRef ref) => ref.watch(
  feedbackServiceProvider.select((FeedbackService s) => s.unseenCount),
);
