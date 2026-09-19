# 长期参考子模块

本目录只放与 Hibiki 构建、运行无依赖关系的上游参考项目。

## ReinaManager

- 上游：<https://github.com/huoshen80/ReinaManager>
- 用途：参考 galgame 游戏库、详情页、启动入口、集合与统计的信息架构；Hibiki 的实现仍使用现有 Flutter / Material 3 技术栈。
- 当前固定提交：`72b8ca255d6e874539a6bfe71029a369debf6c0a`（2026-07-15，`v0.25.0-3-g72b8ca2`）。
- 上游许可证：AGPL-3.0；Hibiki 为 GPL-3.0。子模块保持独立上游历史与许可证，不把其 React/Tauri 源码、角色图标、截图或其它素材直接复制进 Hibiki。若未来要移植代码或素材，必须先单独做许可证与署名审查。

首次拉取：

```bash
git submodule update --init --recursive references/ReinaManager references/mangayomi
```

有意识地更新固定版本：

```bash
git -C references/ReinaManager fetch origin
git -C references/ReinaManager checkout <reviewed-commit-or-tag>
git add references/ReinaManager
```

更新时同时复核许可证、截图与本文记录；不要把子模块改成 Hibiki 的运行时依赖。

## mangayomi

- 上游：<https://github.com/kodjodevf/mangayomi>
- 用途：Aniyomi / Mihon 扩展在桌面（M-Extension-Server sidecar `/dalvik` JSON RPC）与 Android 上的适配参考——`lib/eval/mihon/service.dart` 的请求形状与响应解析、`lib/services/get_video_list.dart` 到 `lib/modules/anime/anime_player_view.dart` 的取流 → 选流 → media_kit 播放链、Cloudflare cookie / UA 回灌、torrent 型源分流。Hibiki 的视频源扩展走本仓 `third_party/m_extension_server`（同一 sidecar 血统，vendored）+ `fushi/lib/src/media/video/online/`，只借鉴调用面与容错，不复制其 Dart 代码。
- 当前固定提交：`6402a7e31a50d24151591b051e59ecb88eecf957`（2026-09-19）。
- 上游许可证：Apache-2.0；Hibiki 为 GPL-3.0。子模块保持独立上游历史与许可证；若未来要移植代码，必须先单独做许可证与署名审查。
