import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_browse_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「Kavita」在漫画「来源」一节里的一行（与 `InterconnectMangaSourceRow` 同级）。
///
/// 只有配了**可用**服务器（启用且有 API key）时才出现，否则整行不占位——没配
/// Kavita 的用户不该看到一个点进去什么都没有的入口。Kavita 是用户自己的服务器，
/// 与互联对端同类，属于用户自配服务器能力（`userConfiguredServersAvailable`，
/// 2026-10-27 用户拍板），iOS 上照常提供。
///
/// 监听 `prefsRepo`（`setKavitaServers` 会 `notifyListeners`）：在设置页加完服务器
/// 回到本页即出现。
class KavitaMangaSourceRow extends ConsumerStatefulWidget {
  const KavitaMangaSourceRow({super.key});

  @override
  ConsumerState<KavitaMangaSourceRow> createState() =>
      _KavitaMangaSourceRowState();
}

class _KavitaMangaSourceRowState extends ConsumerState<KavitaMangaSourceRow> {
  late final AppModel _appModel = ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _appModel.prefsRepo.addListener(_onChanged);
  }

  @override
  void dispose() {
    _appModel.prefsRepo.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<KavitaServerConfig> usable = usableKavitaServers(
      _appModel.prefsRepo.kavitaServers,
    );
    if (usable.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FushiCard(
        padding: EdgeInsets.zero,
        child: FushiListItem(
          key: const ValueKey<String>('manga_source_kavita'),
          leading: const FushiListLeadingIcon(
            FushiIcons.cloud,
            shape: FushiLeadingShape.cookie,
            tone: FushiCardTone.primary,
          ),
          title: Text(t.kavita_source_name),
          subtitle: Text(t.kavita_source_subtitle),
          trailing: const FushiIcon(FushiIcons.chevronRight),
          onTap: () => Navigator.of(context).push(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) => const KavitaBrowsePage(),
            ),
          ),
        ),
      ),
    );
  }
}
