## BUG-5217 · music-sources-switch-away-notify
- **报告**：2026-11-22（代码审查 HBK-AUDIT-218，PR #4129）
- **真实性**：✅ 真 bug。「在线 › 来源」视图（`MusicOnlineSourcesView`）嵌在曲库页「在线」组里，切页签就 dispose。Apple Music / YouTube 启用开关、Apple Music 地区、「添加 › 服务器」走旧 `_reloadAndNotify`（`fushi/lib/src/pages/implementations/music/music_sources_page.dart:228-233`，`if (!mounted) return` 在通知宿主之前）：偏好写入期间用户切走，偏好已落库，但宿主（`music_library_page.dart` `_onOnlineSourcesChanged`）收不到通知，推荐页签、统一搜索来源、混排的服务器专辑停在旧来源配置上，直到别的事件触发重读。普通来源分支（`_commit`，`:182-195`）在 await 之后才经本 State 取 `widget.onChanged`，通知的所有者是已卸载的视图。宿主的 `_onOnlineSourcesChanged` 也不判 mounted，宿主已关时 `_reloadOnlineSources` 会先经 `ref.read` 取 AppModel。
- **[x] ① 已修复** — 通知的所有者改成宿主：`_commit` 与新的 `_persistThenReload(change)` 在动手前同步取好宿主回调，写完无论本视图在不在都通知宿主（本视图还在时才重读本页）；Apple Music / YouTube 开关、地区、「添加」菜单都走 `_persistThenReload`。宿主 `_onOnlineSourcesChanged` 先判 mounted。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_sources_pages_test.dart`「来源页：启用开关写入途中切走，写完照样通知宿主」：偏好写入卡在闸门上（`_GatedPrefs`），点 YouTube 启用开关后把视图换掉、再放行写入，断言偏好已写、宿主回调恰好一次、无异常。变异实测：还原修复后该用例红（宿主回调 0 次），恢复后绿。
- **备注**：
