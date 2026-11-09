## BUG-4273 · Electron/Chromium 打包游戏经 Fushi 启动即崩（不可读 PE 节被扫描）
- **报告**：2026-11-09（用户：应用内反馈 CTird9n2aD「fushi点击启动游戏没启动游戏。手动点击启动」，Windows 3.3.0-debug.24790；游戏为 TyranoScript 的 Electron 24 打包作品 ユリアリス）
- **真实性**：✅ 真 bug。本机原始路径复现：`fushi_voice_injector --launch yurialice.exe` 注入 hook DLL 后约 1 s 游戏进程以 `0xC0000005` 退出（主线程尚未恢复），反馈日志里随后的 `VirtualAllocEx failed: 5` 就是进程已死。cdb 栈：`HookWorker → AdapterRegistry::InstallStartupAdapters → MalieLibpAdapter::install → TryHookMalieDecoderVoice → MeasureMalieProfile → malie_io::ImageFingerprint`（`native/galgame_hook/hook/adapters/malie_engine_io_core.h:447`）。根因在共享层 `native/galgame_hook/hook/adapters/exact_lookup_signature.h` `OpenLoadedPeImage`：按节头把每个节的 `bytes/size` 交给各引擎扫描器，不看内存是否可读；Chromium/Electron exe 的 `.retplne` 节 `Characteristics = 0`（无 `IMAGE_SCN_MEM_READ`），加载器映射成 `PAGE_NOACCESS`，指纹扫到即 AV。不加注入直接启动同一 exe 正常。
- **[x] ① 已修复** — `OpenLoadedPeImage` 对不可读的节保留 rva/属性、但给 `bytes = nullptr, size = 0`（`FindSectionForRva` 不命中、扫描循环零次迭代；Siglus 与 `FindUniquePatternInExecutableSections` 对不可读可执行节照旧 fail closed）。提交 eb8adc0a63。修后同一启动路径：游戏主进程 + 4 个子进程存活，hook 2.9 s 就绪（不再 5 s 超时），LunaHook 注入并连接。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/loaded_pe_unreadable_section_test.cpp`（CTest `fushi_loaded_pe_unreadable_section_test`）：合成带 `PAGE_NOACCESS` `.retplne` 节的 x64 映像，断言该节不交出字节、Malie 指纹 / 身份探测不崩、不可读可执行节仍 fail closed。未修复代码上断言失败、修复后通过（已实测）。
- **备注**：同一 PR 里接着做了 TyranoScript（Electron / NW.js）的引擎级游戏内查词适配。Electron 的台词在 `--type=renderer` 子进程渲染，注入的主进程拿不到文本，所以文本和几何都改为从页面 DOM 经 CDP 获取：
  - **启动**：对 Tyrano 游戏追加 `--remote-debugging-port`。判定只看目录结构（`app.asar` 顶层有 `tyrano/`），不看 exe 名。
  - **文本**：逐字的 `span.char` 拼成台词，作为 `tyrano_dom` 行进入 texthooker。DOM 源在线时，LunaHook 的行不再作为正文。
  - **几何**：attached surface 新增「实测排版」模式，直接接收 DOM 实测的逐字客户区物理像素矩形，免校准，吞点击与弹卡沿用现有链路。
  - **语音**：用引擎自己的判据 `stat.map_vo.vobuf[buf]`，挂在 `playbgm.start` 上，按句序号精确归属；宿主按 asar 偏移读出原件写进 dump。三条语音原件的 SHA-256 与 asar 成员一致。原生侧 `IsVoiceAudioPath` 里写死的 `data/sound/v_` 文件名猜测没有改，DOM 源在线时由仲裁绕开。

  未做真机四条验收（游戏内弹卡、点击查词不推进的鼠标与触摸、自然推进下的语音配对），属于 `implemented_unverified`，所以 `engine-support.yaml` 不升级。
