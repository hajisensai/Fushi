import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';
import 'package:hibiki/src/pages/implementations/download_actions.dart';
import 'package:hibiki/src/pages/implementations/download_tasks_list.dart';
import 'package:hibiki/src/pages/implementations/torrent_settings_section.dart';
import 'package:hibiki/utils.dart';

/// 独立「下载」页（顶层底栏 tab）：把 torrent 下载从视频页头拿出来单独成页。
/// 通用磁力添加（书/视频/任意）+ 番剧搜索入口 + 下载任务列表。完成后按内容
/// 类型自动入库（视频→视频库、epub→阅读库，见 AnimeDownloadService）。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  final TextEditingController _magnetCtrl = TextEditingController();
  final ValueNotifier<int> _tasksRefresh = ValueNotifier<int>(0);
  String _kind = AnimeDownloadPlan.kindAuto;
  bool _pushing = false;

  @override
  void dispose() {
    _magnetCtrl.dispose();
    _tasksRefresh.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _push() async {
    if (_pushing) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _pushing = true);
    final GenericPushOutcome outcome = await pushGenericMagnet(
      context: context,
      appModel: appModel,
      magnet: _magnetCtrl.text,
      contentKind: _kind,
    );
    if (!mounted) return;
    setState(() => _pushing = false);
    _snack(genericPushMessage(outcome));
    if (outcome == GenericPushOutcome.ok) {
      _magnetCtrl.clear();
      _tasksRefresh.value++; // 重载任务列表让新任务立刻出现。
    }
  }

  Future<void> _openAnimeSearch() async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => const AnimeDownloadDialog(),
    );
    _tasksRefresh.value++;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool ready = torrentBackendReady(ref.watch(appProvider));
    return Scaffold(
      appBar: AppBar(
        title: Text(t.nav_downloads),
        actions: <Widget>[
          IconButton(
            tooltip: t.anime_download_title,
            icon: const Icon(Icons.travel_explore),
            onPressed: _openAnimeSearch,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(t.anime_download_generic_title,
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _magnetCtrl,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: t.anime_download_generic_hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: <ButtonSegment<String>>[
                    ButtonSegment<String>(
                      value: AnimeDownloadPlan.kindAuto,
                      label: Text(t.anime_download_kind_auto),
                    ),
                    ButtonSegment<String>(
                      value: AnimeDownloadPlan.kindVideo,
                      label: Text(t.anime_download_kind_video),
                    ),
                    ButtonSegment<String>(
                      value: AnimeDownloadPlan.kindBook,
                      label: Text(t.anime_download_kind_book),
                    ),
                  ],
                  selected: <String>{_kind},
                  onSelectionChanged: _pushing
                      ? null
                      : (Set<String> s) => setState(() => _kind = s.first),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (!ready || _pushing) ? null : _push,
                icon: const Icon(Icons.download, size: 18),
                label: Text(t.anime_download_generic_download),
              ),
            ],
          ),
          if (!ready) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              t.download_backend_not_configured,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const Divider(height: 32),
          // 下载设置（后端/限速/上传/做种/内存）——从「设置→视频」搬到这里，
          // 未就绪时默认展开引导配置。
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: !ready,
              leading: const Icon(Icons.settings_outlined),
              title: Text(t.download_settings),
              childrenPadding: const EdgeInsets.only(bottom: 12),
              children: const <Widget>[TorrentSettingsSection()],
            ),
          ),
          const Divider(height: 32),
          DownloadTasksList(refreshSignal: _tasksRefresh),
        ],
      ),
    );
  }
}
