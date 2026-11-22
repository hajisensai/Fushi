/// 音乐「导入」视图（导入稿 v2 第二节 4，IM12 / IM20 已拍板）：导入钮不再弹菜单，
/// 与书 / 漫画 / 视频 / 游戏一样切到导入视图，套同一个 [ImportCollagePage]。
///
/// - 原导入菜单的动作全部变成方式块，不删入口：添加音乐文件夹（主方式）· 添加音频
///   文件 · 添加光盘（光盘文件夹 / 光盘镜像二选一）· 读取音频 CD（仅桌面三端，
///   [musicAudioCdSupported]）· 网络共享（新入口，直接开网络来源表单）；
/// - 常驻来源（本地 / 网络文件夹 + Fushi 互联块）从「来源 › 本地文件夹」对话框搬到
///   这一页（来源管理对话框的音乐入口已随「来源」页并进「在线」组下线，本地文件夹只在这里管）；
/// - 拖放（拍板台 left3568）：spec 的 onDrop 就是曲库页的整页落点处理（IM2，不另写
///   分发）——目录登记成音乐来源，曲目文件（纯音频 + MV 视频容器）导入曲库。
library;

import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart' show SourceLibraryKind;
import 'package:fushi_engine/media/media_extensions.dart'
    show kAudioExtensions, kVideoExtensions;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart'
    show FileDropCallback;
import 'package:fushi/src/media/import/import_choice_dialog.dart';
import 'package:fushi/src/media/import/import_collage_page.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 「添加光盘」方式块里的二选一：光盘文件夹（DVD / BD 目录、光驱根，或目录树里的
/// `.iso`，`pickAndAddMusicDiscs`）与直接选光盘镜像文件（`pickAndAddMusicDiscImages`）。
enum MusicDiscImportPick { folder, image }

/// 「添加光盘」认得的光盘形态（不带点）：`.iso` 镜像与蓝光目录的 `BDMV`。与
/// `music_disc_actions.dart` 的光盘识别同口径，只给格式气泡用。
const Set<String> kMusicDiscImportFormats = <String>{'iso', 'bdmv'};

/// 音乐导入面的 spec（纯函数，便于单测：方式顺序 / 音频 CD 门 / 网络说明）。
///
/// 方式按规范顺序：主方式（添加音乐文件夹）→ 其他（音频文件 · 光盘 · 音频 CD）→
/// 网络共享。[audioCdSupported] = false 时（移动端）没有音频 CD 块。
ImportSurfaceSpec musicImportSurfaceSpec({
  required Future<void> Function() onAddFolder,
  required Future<void> Function() onAddAudioFiles,
  required Future<void> Function() onAddDisc,
  required Future<void> Function() onReadCd,
  required Future<void> Function() onAddNetworkSource,
  required bool audioCdSupported,
  bool enabled = true,
  FileDropCallback? onDrop,
}) {
  final String mediaKind = SourceLibraryKind.music.dbValue;
  return ImportSurfaceSpec(
    id: 'music',
    tone: ImportTone.rose,
    guideIcon: FushiIcons.music,
    guideTitle: t.import_guide_music_title,
    guideDescription: t.import_guide_music_desc,
    methods: <ImportMethod>[
      ImportMethod(
        id: 'music-add-folder',
        kind: ImportMethodKind.primary,
        icon: FushiIcons.folder,
        label: t.music_folder_add,
        description: t.import_method_music_folder_desc,
        destination: ImportDestination.pickFolder,
        // 选目录 → 登记 → 扫描，不弹对话框：块上转圈到扫描结束（IM14）。
        reportsProgress: true,
        enabled: enabled,
        onTap: onAddFolder,
      ),
      ImportMethod(
        id: 'music-add-audio-files',
        // 「音频文件」没有专属方式类型，取 t1（与有声书同为音频，同色）。
        kind: ImportMethodKind.audiobook,
        icon: FushiIcons.music,
        label: t.import_method_music_audio_files,
        description: t.import_method_music_audio_files_desc,
        destination: ImportDestination.pickFile,
        reportsProgress: true,
        enabled: enabled,
        onTap: onAddAudioFiles,
      ),
      ImportMethod(
        id: 'music-add-disc',
        kind: ImportMethodKind.disc,
        icon: FushiIcons.storage,
        label: t.music_disc_add,
        description: t.import_method_music_disc_desc,
        destination: ImportDestination.choice,
        reportsProgress: true,
        enabled: enabled,
        onTap: onAddDisc,
      ),
      if (audioCdSupported)
        ImportMethod(
          id: 'music-read-cd',
          kind: ImportMethodKind.audioCd,
          icon: FushiIcons.audio,
          label: t.music_cd_read,
          description: t.import_method_music_cd_desc,
          destination: ImportDestination.pickDrive,
          enabled: enabled,
          onTap: onReadCd,
        ),
      ImportMethod(
        id: 'music-network',
        kind: ImportMethodKind.network,
        icon: FushiIcons.cloud,
        label: t.media_source_add_network,
        description: importNetworkTransportsSummary(mediaKind),
        destination: ImportDestination.source,
        enabled: enabled,
        onTap: onAddNetworkSource,
      ),
    ],
    formatGroups: <ImportFormatGroup>[
      ImportFormatGroup(
        title: t.nav_music,
        labels: importFormatLabels(<Iterable<String>>[kAudioExtensions]),
      ),
      // 音乐来源里的视频容器作为 MV 进曲库（只放音轨、可在视频播放页看画面）。
      ImportFormatGroup(
        title: t.music_track_mv_badge,
        labels: importFormatLabels(<Iterable<String>>[kVideoExtensions]),
      ),
      ImportFormatGroup(
        title: t.music_import_group_disc,
        labels: importFormatLabels(<Iterable<String>>[kMusicDiscImportFormats]),
      ),
    ],
    onDrop: onDrop,
  );
}

/// 音乐导入视图本体：方式块的动作由曲库页交进来（与原菜单同一批函数，扫描中标记、
/// 盘面图失效、重读曲库都在曲库页那一侧），来源区是 `MediaSourcesView` 的色块呈现。
class MusicImportView extends StatelessWidget {
  const MusicImportView({
    required this.sourcesKey,
    required this.onAddFolder,
    required this.onAddAudioFiles,
    required this.onAddDiscFolder,
    required this.onAddDiscImages,
    required this.onReadCd,
    required this.audioCdSupported,
    this.onLibraryChanged,
    this.onDrop,
    this.busy = false,
    super.key,
  });

  /// 来源区状态句柄：区头「＋ 添加来源」与「网络共享」方式块经它调
  /// `addSource` / `addNetworkSource`。
  final GlobalKey<MediaSourcesViewState> sourcesKey;
  final Future<void> Function() onAddFolder;
  final Future<void> Function() onAddAudioFiles;
  final Future<void> Function() onAddDiscFolder;
  final Future<void> Function() onAddDiscImages;
  final Future<void> Function() onReadCd;
  final bool audioCdSupported;

  /// 来源扫描收尾（曲库页借此让盘面图索引失效并重读）。
  final VoidCallback? onLibraryChanged;

  /// 曲库页的整页落点处理（null = 不收拖放）。
  final FileDropCallback? onDrop;

  /// 曲库页正在扫描 / 导入：方式块与「添加来源」暂不可点。
  final bool busy;

  /// 「添加光盘」：先问是光盘文件夹还是镜像文件，再走原菜单里对应的那条流程。
  Future<void> _addDisc(BuildContext context) async {
    final MusicDiscImportPick? pick =
        await showImportChoiceDialog<MusicDiscImportPick>(
          context: context,
          title: t.music_disc_add,
          options: <ImportChoiceOption<MusicDiscImportPick>>[
            ImportChoiceOption<MusicDiscImportPick>(
              key: const ValueKey<String>('music-disc-pick-folder'),
              value: MusicDiscImportPick.folder,
              icon: FushiIcons.folderOpen,
              title: t.music_import_disc_folder,
            ),
            ImportChoiceOption<MusicDiscImportPick>(
              key: const ValueKey<String>('music-disc-pick-image'),
              value: MusicDiscImportPick.image,
              icon: FushiIcons.storage,
              title: t.music_import_disc_image,
            ),
          ],
        );
    if (pick == null || !context.mounted) return;
    switch (pick) {
      case MusicDiscImportPick.folder:
        await onAddDiscFolder();
      case MusicDiscImportPick.image:
        await onAddDiscImages();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ImportSurfaceSpec spec = musicImportSurfaceSpec(
      onAddFolder: onAddFolder,
      onAddAudioFiles: onAddAudioFiles,
      onAddDisc: () => _addDisc(context),
      onReadCd: onReadCd,
      onAddNetworkSource: () async =>
          sourcesKey.currentState?.addNetworkSource(),
      audioCdSupported: audioCdSupported,
      enabled: !busy,
      onDrop: onDrop,
    );
    return ImportCollagePage(
      spec: spec,
      sources: MediaSourcesView(
        key: sourcesKey,
        mediaKind: SourceLibraryKind.music.dbValue,
        presentation: MediaSourcesPresentation.blocks,
        entranceIndexOffset: spec.sourceEntranceIndex,
        onLibraryChanged: onLibraryChanged,
      ),
      onAddSource: () => unawaited(sourcesKey.currentState?.addSource()),
      addSourceEnabled: !busy,
    );
  }
}
