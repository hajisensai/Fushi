/// 「本版新内容」页：从上次看过的版本到现在这个版本，多了什么。
///
/// 内容不手写，取两处现成数据：
/// - 本机跑的是**调试包**且两端序号都知道：调试版流水线（`debug-pulse-fushi.json`）
///   里落在 `(上次, 现在]` 的各个包的 PR 标题，按 新功能 / 修复 / 优化 / 其他 分组
///   （与更新中心的流水线面板同一个列表组件）。流水线只留最近一批包，区间开头被
///   截掉时页尾提示去看更新日志。
/// - 否则（正式版 / 预发布）：GitHub release 里版本落在区间内的发布说明（与「查看
///   更新日志」页同一个版本卡片）。
library;

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/src/pages/implementations/changelog_page.dart';
import 'package:fushi/src/pages/implementations/debug_pulse_panel.dart';
import 'package:fushi/src/updates/debug_pulse_service.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart' show UpdateChannel;
import 'package:fushi/src/utils/misc/update_checker.dart'
    show
        channelForUpdateVersion,
        fetchAllGitHubReleases,
        isAppVersionRelease,
        isVersionNewer;
import 'package:fushi_engine/updates/debug_pulse.dart';

/// 版本落在 `(fromVersion, toVersion]` 的应用版本 release（保持输入顺序）。
List<Map<String, dynamic>> releasesBetween(
  List<Map<String, dynamic>> releases, {
  required String fromVersion,
  required String toVersion,
}) => <Map<String, dynamic>>[
  for (final Map<String, dynamic> r in releases)
    if (isAppVersionRelease(r))
      if (_releaseVersion(r) case final String v
          when isVersionNewer(v, fromVersion) && !isVersionNewer(v, toVersion))
        r,
];

/// release 的版本串（tag 去掉前导 v）。[isAppVersionRelease] 已保证 tag 是版本号。
String? _releaseVersion(Map<String, dynamic> release) {
  final Object? tag = release['tag_name'];
  return tag is String ? tag.trim().replaceFirst(RegExp('^[vV]'), '') : null;
}

/// 调试包走流水线的条件：本机是调试包，且上次 / 现在的序号都知道。
bool whatsNewUsesDebugPulse({
  required String toVersion,
  required int fromSeq,
  required int? toSeq,
}) =>
    channelForUpdateVersion(toVersion) == UpdateChannel.debug &&
    fromSeq > 0 &&
    toSeq != null &&
    toSeq > fromSeq;

class WhatsNewPage extends StatefulWidget {
  const WhatsNewPage({
    super.key,
    required this.fromVersion,
    required this.fromSeq,
    required this.toVersion,
    required this.toSeq,
    this.customProxy = '',
    this.pulseService,
    this.fetchReleases,
  });

  final String fromVersion;

  /// 0 = 未知。
  final int fromSeq;
  final String toVersion;
  final int? toSeq;
  final String customProxy;

  /// 测试注入口；生产用 [DebugPulseService.instance]。
  final DebugPulseService? pulseService;

  /// 测试注入口；生产用 [fetchAllGitHubReleases]。
  final Future<List<Map<String, dynamic>>> Function()? fetchReleases;

  @override
  State<WhatsNewPage> createState() => _WhatsNewPageState();
}

sealed class _Content {
  const _Content();
}

final class _PulseContent extends _Content {
  const _PulseContent(this.report, this.range);
  final DebugPulseReport report;
  final DebugPulseRange range;
}

final class _ReleaseContent extends _Content {
  const _ReleaseContent(this.releases);
  final List<Map<String, dynamic>> releases;
}

final class _EmptyContent extends _Content {
  const _EmptyContent();
}

class _WhatsNewPageState extends State<WhatsNewPage>
    with FushiPagePlaceholders<WhatsNewPage> {
  _Content? _content;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _content = null);
    final _Content content = await _fetch();
    if (!mounted) return;
    setState(() => _content = content);
  }

  Future<_Content> _fetch() async {
    final int? toSeq = widget.toSeq;
    if (toSeq != null &&
        whatsNewUsesDebugPulse(
          toVersion: widget.toVersion,
          fromSeq: widget.fromSeq,
          toSeq: toSeq,
        )) {
      final DebugPulseService service =
          widget.pulseService ?? DebugPulseService.instance;
      final DebugPulseReport? report = await service.refresh(
        customProxy: widget.customProxy,
      );
      if (report != null) {
        final DebugPulseRange range = report.changesBetween(
          afterSeq: widget.fromSeq,
          throughSeq: toSeq,
        );
        if (!range.isEmpty) return _PulseContent(report, range);
      }
    }
    final List<Map<String, dynamic>> all =
        await (widget.fetchReleases?.call() ??
            fetchAllGitHubReleases(customProxy: widget.customProxy));
    final List<Map<String, dynamic>> inRange = releasesBetween(
      all,
      fromVersion: widget.fromVersion,
      toVersion: widget.toVersion,
    );
    return inRange.isEmpty ? const _EmptyContent() : _ReleaseContent(inRange);
  }

  void _openChangelog() {
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => ChangelogPage(customProxy: widget.customProxy),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.whats_new_title,
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.history,
          tooltip: t.settings_view_changelog,
          onTap: _openChangelog,
        ),
        FushiIconButton(
          icon: FushiIcons.refresh,
          tooltip: t.refresh,
          onTap: _content == null ? null : () => unawaited(_load()),
        ),
      ],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildBody(BuildContext context) {
    final _Content? content = _content;
    if (content == null) {
      return SafeArea(bottom: false, child: buildLoading());
    }
    if (content is _EmptyContent) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: FushiIcons.celebration,
          message: t.whats_new_empty,
          action: FushiFilledButton.icon(
            onPressed: _openChangelog,
            icon: const FushiIcon(FushiIcons.history),
            label: Text(t.settings_view_changelog),
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> items = <Widget>[
      _RangeHeader(
        fromVersion: widget.fromVersion,
        toVersion: widget.toVersion,
        content: content,
      ),
      ...switch (content) {
        _PulseContent(:final DebugPulseReport report, :final range) => <Widget>[
          DebugPulseChangeList(report: report, changes: range),
          if (!range.complete) _IncompleteNote(onOpenChangelog: _openChangelog),
        ],
        _ReleaseContent(:final List<Map<String, dynamic>> releases) => <Widget>[
          for (int i = 0; i < releases.length; i++)
            ChangelogReleaseCard(release: releases[i], latest: i == 0),
        ],
        _EmptyContent() => const <Widget>[],
      },
    ];
    return FushiEntranceScope(
      replayKey: content,
      child: ListView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: items.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card),
            child: items[index],
          ),
        ),
      ),
    );
  }
}

/// 页首：「从 A 更新到 B」+（调试包时）各类改动数。
class _RangeHeader extends StatelessWidget {
  const _RangeHeader({
    required this.fromVersion,
    required this.toVersion,
    required this.content,
  });

  final String fromVersion;
  final String toVersion;
  final _Content content;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : theme.colorScheme.tertiaryContainer;
    final Color onFill = apple
        ? tokens.surfaces.onSurface
        : theme.colorScheme.onTertiaryContainer;
    final Map<DebugPulsePrKind, int> counts = <DebugPulsePrKind, int>{};
    if (content case _PulseContent(:final report, :final range)) {
      for (final int n in range.prNumbers) {
        final DebugPulsePrKind kind = report.pr(n).kind;
        counts[kind] = (counts[kind] ?? 0) + 1;
      }
    }
    return DecoratedBox(
      key: const ValueKey<String>('whats-new-header'),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(apple ? 12 : 28),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Row(
          children: <Widget>[
            FushiIcon(FushiIcons.celebration, size: 28, color: onFill),
            SizedBox(width: tokens.spacing.card),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.whats_new_range(from: fromVersion, to: toVersion),
                    style: context.fushiType.titleMedium.copyWith(
                      color: onFill,
                    ),
                  ),
                  if (counts.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final DebugPulsePrKind kind
                            in DebugPulsePrKind.values)
                          if (counts[kind] case final int n)
                            FushiTag(
                              text: '${debugPulseKindLabel(kind)} $n',
                              tone: debugPulseKindTone(kind),
                            ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncompleteNote extends StatelessWidget {
  const _IncompleteNote({required this.onOpenChangelog});

  final VoidCallback onOpenChangelog;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey<String>('whats-new-incomplete'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.whats_new_incomplete,
          style: context.fushiType.bodySmall.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        FushiTextButton(
          onPressed: onOpenChangelog,
          child: Text(t.settings_view_changelog),
        ),
      ],
    );
  }
}
