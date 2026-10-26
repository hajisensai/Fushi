import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/video_settings_cli_ops.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 播放页「着色器」视图里不是记录列表的那几样操作在控制通道上的条目（着色器文件
/// 列表本身是 schema 行 `video.player.shaders` 的 cliList）：画质档位、从本机 mpv
/// 发现 / 导入、mpv 着色器目录。实现见 `video_settings_cli_ops.dart`。
///
/// 值都是全局偏好：没有播放页时写入下次播放生效，播放中即时应用。
List<CtlBodyPage> buildCtlVideoShaderBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: t.video_shader_quality_tier,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: 'video.player.shader_tier',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.video_shader_quality_tier,
        cliValue: SettingsCliValue(
          offPageWritable: true,
          read: videoShaderTierNameFromPrefs,
          write: (SettingsContext c, String raw) async {
            await selectVideoShaderTierForCli(c, raw);
          },
          help: '一键选档：缺的 Anime4K 着色器先下载，再启用（custom = 手工勾选，只读）',
          options: (SettingsContext _) => <String>[
            for (final VideoShaderTier tier in VideoShaderTier.values)
              tier.name,
          ],
        ),
      ),
      SettingsCustomItem(
        id: 'video.player.mpv_shader_dir',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.video_shader_pick_mpv_dir,
        cliValue: SettingsCliValue(
          offPageWritable: true,
          read: (SettingsContext c) => c.appModel.videoMpvShaderDir,
          write: setVideoMpvShaderDirForCli,
          help: '本机 mpv 配置 / 着色器目录（绝对路径；空串 = 自动找）',
        ),
      ),
      SettingsActionItem(
        id: 'video.player.shader_discover',
        title: t.video_shader_import_from_mpv,
        subtitle: t.video_shader_import_from_mpv_hint,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          offPageRunnable: true,
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'dir',
              help: '先把这个目录记成 mpv 目录再扫（同手动指定目录）',
              required: false,
              path: true,
            ),
            SettingsCliParam(
              'import',
              help: 'all 或逗号分隔的文件名：导入到着色器目录；省略 = 只列出',
              required: false,
            ),
          ],
          run: (SettingsContext c, Map<String, String> args) =>
              discoverVideoMpvShadersForCli(
                c,
                dir: args['dir'],
                import: args['import'],
              ),
        ),
      ),
    ],
  ),
];
