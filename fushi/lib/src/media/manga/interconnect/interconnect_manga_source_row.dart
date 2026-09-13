import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/utils.dart';

/// 「Fushi 互联」在漫画「来源」一节里的**合集**（与 [MokuroMoeSourceRow] 同级）。
///
/// 头行 = 合集总开关 + 展开箭头；展开后每个子项各自可关：
///   · 「对端漫画库」——对端已下载的漫画，走既有 `InterconnectMangaBrowsePage`；
///   · 每个对端透出的扩展源（Mihon / Aidoku，跑在对端、本机经它代理浏览）。
/// 三层开关都是本机偏好，只管漫画；互联**总开关**仍在本地来源节 / 同步设置页，
/// 关着时头行禁用并直说去哪儿开。
///
/// 扩展源子项受商店合规边界约束（iOS 不列，与 Mihon / Aidoku / mokuro.moe 同门，
/// 判据只在 [StoreRestrictedCapability.onlineMangaSource]）；对端漫画库子项不受。
class InterconnectMangaSourceRow extends ConsumerStatefulWidget {
  const InterconnectMangaSourceRow({super.key, this.registryOverride});

  /// 测试注入口；生产恒用 [AppModel.interconnectMangaSourceRegistry]。
  final InterconnectMangaSourceRegistry? registryOverride;

  @override
  ConsumerState<InterconnectMangaSourceRow> createState() =>
      _InterconnectMangaSourceRowState();
}

class _InterconnectMangaSourceRowState
    extends ConsumerState<InterconnectMangaSourceRow> {
  InterconnectMangaSourceRegistry? _registry;
  bool _expanded = true;

  InterconnectMangaSourceRegistry get _reg =>
      _registry ??= widget.registryOverride ??
          ref.read(appProvider).interconnectMangaSourceRegistry;

  @override
  void initState() {
    super.initState();
    _reg.addListener(_changed);
    unawaited(_reg.ensureFresh());
  }

  @override
  void dispose() {
    _registry?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _sourcesAllowed =>
      StoreRestrictedCapability.onlineMangaSource.isAvailable;

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    final InterconnectMangaSourceRegistry reg = _reg;
    final bool interconnectOn = reg.interconnectEnabled;
    final bool collectionOn = reg.collectionEnabled;
    final bool childrenOn = interconnectOn && collectionOn;
    final List<InterconnectRemoteSource> sources =
        _sourcesAllowed ? reg.sources : const <InterconnectRemoteSource>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiCard(
          padding: EdgeInsets.zero,
          child: FushiListItem(
            key: const ValueKey<String>('manga_source_interconnect'),
            leading: Switch.adaptive(
              value: interconnectOn && collectionOn,
              onChanged: interconnectOn
                  ? (bool value) => unawaited(
                        appModel.prefsRepo.setMangaInterconnectSourcesEnabled(
                          value,
                        ),
                      )
                  : null,
            ),
            title: Text(t.audio_source_fushi_interconnect),
            subtitle: Text(
              interconnectOn
                  ? t.manga_source_interconnect_collection_subtitle
                  : t.manga_source_interconnect_disabled,
            ),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (_sourcesAllowed)
                  IconButton(
                    key: const ValueKey<String>(
                      'manga_source_interconnect_refresh',
                    ),
                    tooltip: t.manga_source_interconnect_refresh,
                    onPressed: interconnectOn && !reg.loading
                        ? () => unawaited(reg.refresh())
                        : null,
                    icon: reg.loading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
        ),
        if (_expanded) ...<Widget>[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiCard(
                  padding: EdgeInsets.zero,
                  child: FushiListItem(
                    key: const ValueKey<String>(
                      'manga_source_interconnect_library',
                    ),
                    leading: Switch.adaptive(
                      value: childrenOn &&
                          appModel.prefsRepo.mangaInterconnectLibraryEnabled,
                      onChanged: childrenOn
                          ? (bool value) => unawaited(
                                appModel.prefsRepo
                                    .setMangaInterconnectLibraryEnabled(value),
                              )
                          : null,
                    ),
                    title: Text(t.manga_source_interconnect_library_title),
                    subtitle: Text(t.manga_source_interconnect_subtitle),
                  ),
                ),
                for (final InterconnectRemoteSource source
                    in sources) ...<Widget>[
                  const SizedBox(height: 8),
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      key: ValueKey<String>(
                        'manga_source_interconnect_${source.id}',
                      ),
                      leading: Switch.adaptive(
                        value: childrenOn && reg.isSourceEnabled(source.id),
                        onChanged: childrenOn
                            ? (bool value) => unawaited(
                                  appModel.prefsRepo
                                      .setMangaInterconnectSourceEnabled(
                                    source.id,
                                    value,
                                  ),
                                )
                            : null,
                      ),
                      title: Text(source.name),
                      subtitle: Text(
                        '${source.language.toUpperCase()} · '
                        '${t.manga_source_interconnect_via_device(device: source.peer.displayName)}',
                      ),
                    ),
                  ),
                ],
                if (_sourcesAllowed &&
                    interconnectOn &&
                    sources.isEmpty &&
                    !reg.loading)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Text(
                      reg.error != null
                          ? '${reg.error}'
                          : t.manga_source_interconnect_no_sources,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
