import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_browse_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';

/// 「Fushi 互联」在漫画「来源」一节里的一行（与 [MokuroMoeSourceRow] 同构、同级）。
///
/// 开关**刻意不在这里**：互联总开关是全应用一个（同步设置页、本地扫描根那一节都能
/// 改），在漫画源里再放一个会让用户以为它只管漫画。这一行只反映它当前是不是开着，
/// 关着时禁用并直说去哪儿开——与 mokuro.moe 那种「源自己的开关」不是一回事。
///
/// 订阅 [SyncRepository.interconnectEnabledRevision] 的理由与 `MediaSourcesView`
/// 一致（BUG-1560）：总开关的另一个写入口在同步设置页，不订阅这条广播的话，从那里
/// 打开互联后回到本页仍是旧状态。
class InterconnectMangaSourceRow extends ConsumerStatefulWidget {
  const InterconnectMangaSourceRow({super.key});

  @override
  ConsumerState<InterconnectMangaSourceRow> createState() =>
      _InterconnectMangaSourceRowState();
}

class _InterconnectMangaSourceRowState
    extends ConsumerState<InterconnectMangaSourceRow> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    SyncRepository.interconnectEnabledRevision.addListener(_onChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    SyncRepository.interconnectEnabledRevision.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => unawaited(_reload());

  Future<void> _reload() async {
    final AppModel appModel = ref.read(appProvider);
    final bool value = await SyncRepository(
      appModel.database,
    ).isInterconnectEnabled();
    if (!mounted || _enabled == value) return;
    setState(() => _enabled = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = _enabled ?? false;
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
        key: const ValueKey<String>('manga_source_interconnect'),
        leading: const Icon(Icons.devices_outlined),
        title: Text(t.audio_source_fushi_interconnect),
        subtitle: Text(
          enabled
              ? t.manga_source_interconnect_subtitle
              : t.manga_source_interconnect_disabled,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled
            ? () => Navigator.of(context).push(
                  adaptivePageRoute<void>(
                    context: context,
                    builder: (BuildContext context) =>
                        const InterconnectMangaBrowsePage(),
                  ),
                )
            : null,
      ),
    );
  }
}
