/// 原盘规格角标（视频库卡片在封面下副行的尾部，2026-10-25 材质定版后封面不压角标）：`BD` / `UHD` / `DVD`，多盘合集 `BD ×3`。
///
/// 规格只按文件结构判（`disc_format.dart`），与「能不能开原盘菜单」无关。视频库的
/// 合集卡 / 单作品卡在用，音乐库的演唱会盘专辑将来同样用它——所以它只吃「成员路径
/// 列表 + 解析器」，不认任何库页类型。
///
/// 与 [VideoSpecsBadgeStrip] 同一纪律：解析器由调用方注入（测试宿主不传就不显示），
/// 自己发起解析、自己重建，卡片其余部分不跟着动。蓝光要读一次 `index.bdmv` 才分得出
/// UHD——没解析完之前**不显示**而不是先画 `BD` 再改成 `UHD`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';

/// 全应用共用一份按盘根缓存的规格解析器（库页、详情页、将来的音乐库）。
final Provider<DiscFormatResolver> discFormatResolverProvider =
    Provider<DiscFormatResolver>((Ref ref) {
      final DiscFormatResolver resolver = DiscFormatResolver();
      ref.onDispose(() => unawaited(resolver.dispose()));
      return resolver;
    });

/// 规格的短标（行业通用缩写，不翻译）。
String discFormatShortLabel(DiscFormat format) => switch (format) {
  DiscFormat.uhdBluray => 'UHD',
  DiscFormat.bluray => 'BD',
  DiscFormat.dvd => 'DVD',
};

/// 汇总 → 角标文字：`BD`、`BD ×3`、混合时 `UHD + BD ×2`；空汇总返回 null。
String? discFormatBadgeLabel(Map<DiscFormat, int> summary) {
  final List<String> parts = <String>[
    for (final DiscFormat format in DiscFormat.values)
      if ((summary[format] ?? 0) > 0)
        summary[format] == 1
            ? discFormatShortLabel(format)
            : '${discFormatShortLabel(format)} ×${summary[format]}',
  ];
  return parts.isEmpty ? null : parts.join(' + ');
}

/// 一组成员的规格汇总是否已有终值（蓝光都读过 `index.bdmv`）。
bool discMembersResolved(
  DiscFormatResolver resolver,
  Iterable<String> memberPaths,
) => memberPaths.every(resolver.isResolved);

/// 封面角标。成员里没有原盘标题时整个不占位。
class DiscFormatBadge extends StatefulWidget {
  const DiscFormatBadge({
    required this.resolver,
    required this.memberPaths,
    super.key,
  });

  /// 规格解析器；null = 宿主没提供（测试或未接线），不显示也不解析。
  final DiscFormatResolver? resolver;

  /// 卡片所代表的条目的成员路径（单作品卡一条，合集卡是全部本地成员）。
  final List<String> memberPaths;

  @override
  State<DiscFormatBadge> createState() => _DiscFormatBadgeState();
}

class _DiscFormatBadgeState extends State<DiscFormatBadge> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(DiscFormatBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolver != widget.resolver ||
        !_samePaths(oldWidget.memberPaths, widget.memberPaths)) {
      _resolve();
    }
  }

  static bool _samePaths(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _resolve() {
    final DiscFormatResolver? resolver = widget.resolver;
    if (resolver == null) return;
    final List<String> paths = <String>[
      for (final String path in widget.memberPaths)
        if (isDiscMemberPath(path)) path,
    ];
    if (paths.isEmpty || discMembersResolved(resolver, paths)) return;
    unawaited(
      resolver.resolveAll(paths).then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DiscFormatResolver? resolver = widget.resolver;
    String? label;
    if (resolver != null) {
      final List<String> paths = <String>[
        for (final String path in widget.memberPaths)
          if (isDiscMemberPath(path)) path,
      ];
      if (paths.isNotEmpty && discMembersResolved(resolver, paths)) {
        label = discFormatBadgeLabel(
          summarizeDiscMembers(paths, resolver.peek),
        );
      }
    }
    // 解析完成那一下淡入（墨水屏 / 减弱动态效果下瞬间到位）。
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      child: label == null
          ? const SizedBox.shrink(key: ValueKey<String>('disc-badge-none'))
          : Semantics(
              key: ValueKey<String>('disc-badge-$label'),
              label: label,
              child: ExcludeSemantics(child: CoverBadge(label: label)),
            ),
    );
  }
}
