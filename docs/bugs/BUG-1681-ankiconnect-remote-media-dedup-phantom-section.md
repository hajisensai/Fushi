## BUG-1681 · 手机连局域网 AnkiConnect 时显示一个必然不可用的媒体存储优化区
- **报告**：2026-08-16（用户：手机看不到 anki 媒体存储优化 —— 顺着这条报告查出来的相邻缺陷）
- **真实性**：✅ 真 bug。根因 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart` 把 `supportsMediaMaintenance` 硬编码 `true`，而实现（同文件 `runMediaDedup`）是 `getMediaDirPath()` 拿到路径后用 `dart:io` **直读本机文件**。

  同一个仓库类既服务「桌面本机 Anki」也服务「手机开了『改用 AnkiConnect』连局域网里的桌面 Anki」。后者拿到的是**那台机器**的路径，本机不存在，`runMediaDedup` 走 `existsSync()` 判否返回 null，设置页只能弹一句 `anki_dedup_unavailable`。也就是：区块显示得出来、点得动、必然不可用。静态的「后端类型支持」被当成了「此刻能不能用」。
- **[x] ① 已修复** — 加一层真实探测 `BaseAnkiRepository.probeMediaMaintenance()`（默认 = 静态能力，不做 I/O；AnkiConnect 覆写为 `_localMediaDir() != null`，与 `runMediaDedup` 共用同一份判据）。`AnkiViewModel.probeMediaMaintenance()` 把结论落进 `AnkiUiState.mediaMaintenanceAvailable`，设置页门控改成 `uiState.mediaMaintenanceAvailable ?? vm.supportsMediaMaintenance`。**后端不可达时保持「未知」**而不是记成「不支持」——否则桌面用户只要在 Anki 没开的时候进过一次设置页，整区就消失了。探测只在设置页 `initState` 发起（一次网络往返，不塞进 vm 构造，避免制卡路径顺带发请求）。
- **[x] ② 已加自动化测试** — `fushi/test/anki/media_maintenance_probe_test.dart`：三态（后端类型不支持 → 不发起探测直接 false / 探到 false / 探到 true）+ 不可达保持 null + 设置页门控源码扫描守卫。守卫已变异实测：门控退回裸 `if (vm.supportsMediaMaintenance)` 时测试转红，还原后文件 sha256 与变异前一致。
- **备注**：与 BUG-1680 / BUG-1682 同批。
