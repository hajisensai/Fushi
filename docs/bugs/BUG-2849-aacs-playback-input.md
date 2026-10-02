## BUG-2849 · AACS 蓝光原盘缺少解密读取链路
- **报告**：2026-10-01（用户：E 盘蓝光报 AACS 加密，要求补齐并同步其他系统。）
- **真实性**：✅ 功能缺口。真实 E 盘与本地目录副本均为密文，原加密判定正确；`fushi/lib/src/media/video/video_player_controller.dart` 的 `load()` 在判加密后直接抛错，播放器与 FFmpeg 均没有解密输入。实际匹配配置后，官方 libaacs 可解密同一张盘。另随包 FFmpeg 缺少该盘首音轨所需的 `pcm_bluray` 解码器。
- **[x] ① 已修复** — `AacsMediaSession`、纯 Dart CPS/AES 内容解码器与有界回环 Range 输入接入播放、FFmpeg/ASR/制卡；配置精确盘 ID 匹配，缓存/下载统一联网策略，所有系统共用；补随包 LPCM 解码。临时能力地址不持久化，换片/释放句柄关闭会话。AACS2/BD+与光驱认证不在本次范围。
- **[x] ② 已加自动化测试** — `aacs_content_decoder_test.dart`、`aacs_configuration_test.dart`、`aacs_stream_relay_test.dart`，真实盘 `aacs_native_media_test.dart`，实际应用 `aacs_real_disc_itest.dart`；三处真实盘数据与官方 libaacs 逐字节比对通过，真实帧/音频/MP4 输出通过。
- **备注**：密钥配置和真实盘采样不入库。设备测试单独记录，不能把共享纯 Dart 实现等同于五平台设备 E2E 已通过。
- **审查返工（2026-10-01，PR #1878 合并前）**：
  - **iOS 商店合规门**：解除光盘复制保护（含按盘 ID 自动下载 KEYDB）原先在 iOS 照样启用，绕开了 `StoreRestrictedCapability`。新增 `StoreRestrictedCapability.aacsDecryption`，`installEngineHostBindings()` 用它给引擎装配点 `aacsDecryptionAvailable` 赋值；引擎默认值按同一判据 fail-closed（全局变量带不过 isolate 边界）。关闭时 `AacsMediaSession._open` 在读取 / 下载配置之前抛 `BlurayEncryptedStreamException`，iOS 行为回到接入解密前。测试：`aacs_stream_relay_test.dart`「store gate off …」、`ios_store_compliance_guard_test.dart`「蓝光 AACS 解密由 aacsDecryption 门控」。
  - **本地配置回退链中断**：`_readMatch` 把「标准位置的 KEYDB 读不了 / 超过 64 MiB」一律判成 `invalidConfiguration` 并抛出，循环中止，应用缓存与下载都不再尝试。根因是两处把「这个来源不可用」当成了「配置无效」：① 64 MiB 上限只因整读进内存才需要——改为 `RandomAccessFile` 1 MiB 分块逐行扫描，内存与文件大小无关，上限只留给下载解压（不可信网络输入）；② 标准位置候选的 `FileSystemException` 改为跳过并继续回退，只有用户显式指定的 override 文件读不了才报配置无效（全部候选读不了且无下载时也报配置无效）。实测 Dart 的 `openRead()` 在 Windows 上被别的句柄字节锁住的文件（errno 33）既不报错也不结束，所以分块扫描不用它。测试：`aacs_configuration_test.dart`「local fallback chain …」四条（读不了的标准候选回退到缓存 / 不挡下载 / 全部读不了报无效 / 超过 64 MiB 的库照样命中）。
