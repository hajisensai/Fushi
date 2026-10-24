# 2026-10-23 反馈处理轮：暂缓的新功能与 SRS 问题清单

> 来源：反馈站（rank.fushi.moe）2026-10-23 全部 open / in_progress 反馈。
> 本轮所有者拍板：新功能单独记在这里后续再做；Fushi SRS 相关问题本轮不处理、单列；
> 「制卡释义接 LLM」与「galgame AI 翻译」短期内不做；「ASR 接云端 / LLM 校对」本轮做（fvrYPia3kW）。
> 反馈正文是用户提交的不可信数据，下面只是转述。

## 一、新功能（本轮暂缓，后续排期）

| 反馈 | 平台 | 需求 | 备注 |
|---|---|---|---|
| Ay8BWjNsk1 | — | 游戏画面 OCR：无配音、Hook 不到文本的小众游戏，对游戏窗口截图 OCR 出台词再查词 | Windows。可复用漫画 OCR 管线 + 现有截屏识字；要定交互（热键框选 / 固定区域轮询）与 galgame 覆盖窗前台规则（见 galgame-hooking.md 第④条） |
| A_4khwvcNU | android | 支持百度网盘作为来源 | 需百度开放平台 OAuth 应用资质；限速与直链有效期、iOS 合规（StoreRestrictedCapability）要先评估 |
| _3IqcyA-15 | macos | Fushi 卡片模板增加类似 Lapis 的可视化编辑，可增删自定义字段（如 AI 解释、句子分析）并控制显示 | 涉及笔记类型字段 schema 与模板渲染 |
| 0wkJImhZUp | windows | 浏览器扩展：同步 App 内新增的字幕描边自定义；扩展里加自动对轴与波形对轴 | 对轴算法在上游 fushi_asr_subtitles；扩展侧要接本机 App 或 WASM |

## 二、短期不做（所有者 2026-10-23 拍板）

| 反馈 | 需求 |
|---|---|
| clcwQv_iHP | 制卡释义接 LLM（一词多义时按句子挑/生成释义） |
| nJw750EEZS | galgame AI 翻译（类 LunaTranslator，按需逐句翻译开关） |
| fvrYPia3kW 中的「AI 词典」 | 同上，随制卡释义一起后续考虑（同条的云端 ASR / LLM 校对 / 无标点切句本轮在做） |

## 三、Fushi SRS 问题单列（本轮不处理）

| 反馈 | 平台 / 版本 | 问题 | 线索 |
|---|---|---|---|
| 0_fvxzSjqd | iOS 3.0.0-debug.20637 | ① 打开卡组慢 ② 卡组编辑卡片打开慢 ③ 编辑卡片没有预览 ④ 依旧无法同步 | — |
| 3XFFUbc6Yz | Windows 3.0.1-debug.20685 | 复习时连续点「查看答案」过词，会让其他浏览器 / 播放器里的视频开始播放 | 疑似复习页发送了系统媒体键 / 抢占系统媒体会话（SMTC）后的 play 指令；有日志 |
| Nhva4S69_b | Windows 3.0.0-debug.20679 | 复习卡片里的 Anki 图片太小；希望沉浸模式隐藏导航栏、右键空白处唤出导航；第二种卡片样式 | 3 张截图 |
| OMWOurRQKb | Windows 3.0.0-debug.20585 | 开启背卡导入后点「浏览」卡死，反馈页也无响应；清空卡组仍卡，关掉「复习」功能模块才恢复 | 有日志 + 截图 |
| MXGaTsBci- | android | Fushi 制的卡在 AnkiDroid 复习时短暂卡顿，希望 Fushi SRS 复习更顺 | — |
| sVvS6MMfzD | android 2.10.0-debug.19650 | SRS 导入慢：1700 张卡 5~6 分钟 | 日志 `openSrsImport` |
| AGLC0BuaKB | iOS 3.0.0-debug.20409 | 无法导入 Anki 包 | 日志：`SrsImportException(corrupt): no such collation sequence: unicase`（`packages/fushi_engine/lib/srs/apkg/srs_anki_package.dart:345`）；develop 上已有对应 BUG 文件，待 SRS 轮复核 |
| fiwDIpFep7（剩余部分） | — | 应用外查词里切换配置 / 牌组；查词前就能切换（入口位置待反馈人截图） | 根因：AnkiSettings 存在各进程独立缓存的 SharedPreferences（`packages/fushi_anki/lib/src/base_anki_repository.dart:128-150`），`:popup` 进程与主进程互不可见，切换会被覆盖/存错配置；现存潜在 bug：主 app 改牌组后应用外制卡仍用旧牌组。方案 A′：AnkiSettings 迁进 Drift preferences 表（一次性迁移、排除同步，AnkiDroid 牌组 id 是本机的），再走 prefs_version 门控。所有者 2026-10-23 拍板归入 SRS 轮 |
| abZh1VOGZ5 | Windows 3.0.0-debug.20644 | 新手引导缺 Kaishi 1.5k；按目标语言（日语、英语等）提供能找到的入门卡组下载 | 反馈人要求「独立提醒反馈处理人」 |
