# 长期参考子模块

本目录只放与 Hibiki 构建、运行无依赖关系的上游参考项目。

## ReinaManager

- 上游：<https://github.com/huoshen80/ReinaManager>
- 用途：参考 galgame 游戏库、详情页、启动入口、集合与统计的信息架构；Hibiki 的实现仍使用现有 Flutter / Material 3 技术栈。
- 当前固定提交：`72b8ca255d6e874539a6bfe71029a369debf6c0a`（2026-07-15，`v0.25.0-3-g72b8ca2`）。
- 上游许可证：AGPL-3.0；Hibiki 为 GPL-3.0。子模块保持独立上游历史与许可证，不把其 React/Tauri 源码、角色图标、截图或其它素材直接复制进 Hibiki。若未来要移植代码或素材，必须先单独做许可证与署名审查。

首次拉取：

```bash
git submodule update --init --recursive references/ReinaManager
```

有意识地更新固定版本：

```bash
git -C references/ReinaManager fetch origin
git -C references/ReinaManager checkout <reviewed-commit-or-tag>
git add references/ReinaManager
```

更新时同时复核许可证、截图与本文记录；不要把子模块改成 Hibiki 的运行时依赖。
