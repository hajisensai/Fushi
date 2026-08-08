# AV 自检实测证据（原 hajisensai/hibiki-hook PR #8 归档副本）

> **为什么这份文件在这里**：native 采集组件已合入本仓，原独立仓 hajisensai/hibiki-hook
> 于 2026-08-08 删除。本仓多处注释（voice_hook_reader.h / galgame_audio_source.dart /
> av-selfscan.yml / voice-hook-helper.yml）把 `hibiki-hook#8` 当作「helper 被杀软零检出」
> 这一判断的**唯一实测证据来源**，删仓前原样归档于此，避免证据随仓库消失。
>
> 原始出处：https://github.com/hajisensai/hibiki-hook/pull/8（状态 MERGED，创建于 2026-07-26T11:11:02Z）

## 标题

chore(ci): helper 产物 Defender 自检 workflow（实证推翻「必被报毒」假设）

## 正文

## 为什么有这个 PR

仓库和 Hibiki 主仓库的部署红线都写着：injector + hook DLL 含 `CreateRemoteThread`/`WriteProcessMemory`，**必被杀软报毒**，因此必须与 `Hibiki.exe` 物理隔离、独立仓库分发。

查 git 历史，这句话自 `e73fe9d5d`（C.1 初版，"部署红线：注入代码隔离出 hibiki.exe 防报毒污染本体"）起就是**预防性判断，从未被任何一次真实扫描验证过**。而 `d53e1238d`（迁出独立仓库）的提交信息自己写清楚了真正的动机是 CI 问题：「根治原 404：主仓库那份 workflow 不在默认分支无法 workflow_dispatch，release 从没被产出」。

用户现在要求把 hook 代码合回 Hibiki（两仓维护成本 + 版本不同步 + **离线用户根本装不上 helper**）。这个决定该不该做，取决于「会不会报毒」这个事实，不能继续靠推测。

## 实测结果

run [30199524916](https://github.com/hajisensai/hibiki-hook/actions/runs/30199524916)，windows-2022，Defender 签名 `1.455.357.0` age=0：

| 对象 | 结果 |
|---|---|
| `voice_hook_x64.zip` / `voice_hook_x86.zip`（含压缩包内扫描） | **clean** |
| x64：`hibiki_voice_hook.dll` / `hibiki_voice_injector.exe` / `LunaHook64.dll` / `LunaHost64.dll` | **clean** |
| x86：上述 + `LoaderDll.dll` / `LocaleEmulator.dll` / `LunaHook32.dll` / `LunaHost32.dll` | **clean** |
| 下载与解压后实时保护是否隔离文件 | 否，全部存活 |
| **EICAR 阳性对照** | **检出 `Virus:DOS/EICAR_Test_File`** |

**「必被杀软报毒」对 Windows Defender 不成立。**

## 两个坑（都已修在本 PR 里，值得记住）

1. **runner 的 Defender 是摆设**：GitHub windows runner 出厂就把整个 `C:\` 和 `D:\` 列为 `ExclusionPath`，且 `RealTimeProtectionEnabled=False`。不先 `Remove-MpPreference` 就扫，拿到的「clean」只等于「压根没扫」。第二次 run 正是因此被阳性对照拦下。
2. **Windows PowerShell 5.1 按 ANSI codepage 解析 .ps1**：run 块里的中文（破折号）直接 parser error。脚本体一律 `pwsh` + 纯 ASCII，中文只留在 YAML 注释（与 BUG-1088 同源的编码坑）。

另外 `MpCmdRun` 检出时返回 exit=2，pwsh 会把它带到 step 末尾中断 job —— 三个扫描步显式 `exit 0`，检出与否改用 `::warning::` + `RESULT:` 行表达。

## 结论的边界（别过度外推）

- 只证明了 **Windows Defender + 该签名版本** 不报。**360 / 火绒 / 腾讯管家未测**，国产杀软对注入类工具的启发式通常更激进，这是剩余风险。
- 未测 SmartScreen 信誉拦截 —— 那是未签名 exe 的固有问题，与病毒库无关，加不加 helper 都一样。
- 签名库会更新，今天不报不等于永远不报。**保留这个 workflow 正是为此**：以后每次发 helper 都能自检，红线是否成立随时可复验。

## 评论

原 PR 仅有一条评论，来自 sonarqubecloud 机器人的 Quality Gate 通知（0 issues / 0 hotspots），
与 AV 自检证据无关，归档时略去。
