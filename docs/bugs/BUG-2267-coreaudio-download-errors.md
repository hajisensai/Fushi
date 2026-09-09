## BUG-2267 · CoreAudio下载失败被误报为qBittorrent推送失败
- **报告**：2026-09-08（用户截图：CoreAudio「若い読者のための哲学史」下载失败，设置选择内置引擎）
- **真实性**：✅ 错误误报为真 bug。`fushi/lib/src/pages/implementations/media_discovery_page.dart:398` 将资源解析异常统一转成推送失败；`fushi/lib/src/pages/implementations/download_actions.dart:163` 吞掉入队异常；同文件 `genericPushMessage` 原来固定使用 qBittorrent 失败文案，成功又一律承诺自动入库。实际后端仍通过 `currentVideoDownloadBackendTarget()` 读取配置，截图不能证明选择错误。
- **[x] ① 已修复** — 本文件同提交：区分解析与入队阶段，种子数据无效、单卷匹配失败和资源获取失败分别提供恢复提示；捕获点记录原始异常与堆栈；通用成功提示改为「已加入下载」，失败不再归咎 qBittorrent。
- **[x] ② 已加自动化测试** — `fushi/test/pages/discovery_torrent_failure_test.dart` 覆盖异常分类、成功语义、阶段及日志调用。该文件与 downloads_center_contract_guard、media_discovery_page、core_audio_discovery_source 共 19 条定向测试通过（退出码 0）。
- **备注**：原始下载失败尚未复现，未宣称修复下载传输。真实目录 `B0BX4ZWYGL` / Nyaa `2006488` 的 616676 字节种子经生产解析器及 matcher 测试通过（1/1）；唯一选中 index 10，588859527 字节，与目录文件名、KiB 大小吻合。没有下载整本音频，也未做用户设备 E2E。等待用户原始日志；本机网络验证不代表用户网络状态。
