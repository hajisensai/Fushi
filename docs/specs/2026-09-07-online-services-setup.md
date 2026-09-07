# 在线服务注册与可选引导

## 应用身份与用户凭据

| 服务 | 应用侧 | 用户侧 |
|---|---|---|
| AniDB | 已注册 UDP `fushiplayer` v1，内置非敏感 client/clientver | 本人 AniDB 账号密码；哈希默认关闭 |
| MAL / Jikan、AniList | 当前公共只读用途无需注册 client | 无需账号或 API key |
| TMDB | 已核实仓库存在 `TMDB_API_KEY`，发布构建统一注入 | 可以用自己的 key 覆盖，不要求每个用户注册应用 |
| DanDanPlay | 已核实 `DANDANPLAY_APP_ID`、`DANDANPLAY_APP_SECRET`，发布构建注入 | 一般不需申请个人 API；自建服务按原设置处理 |
| OpenSubtitles | 已创建 `FushiPlayer` consumer，构建通过 `OPENSUBTITLES_API_KEY` 注入 | 个人登录可用对应下载额度；也可自配 key |
| Jimaku | 不共享个人 key 作为全应用身份 | 本人在账户页生成 key |
| Torznab、Jellyfin/Emby、OPDS | 没有统一应用登记 | 现有服务器地址及管理员提供的账号/key |

API 登录/服务端可用性与“已配置凭据”不同；界面只说明注册要求和当前构建是否内置，不把非空密钥宣称为在线验证成功。开发 worktree 的空占位与发布 CI 的密钥注入也不同，不能据本地占位重复申请。

## 本轮登记证据

- AniDB 项目：[Fushi / 20715](https://anidb.net/software/20715)。UDP client `fushiplayer`，client ID 29913，version 1（版本记录27688），注册结果明确为 active / official。
- [旧 AniDB UDP Clients wiki](https://wiki.anidb.net/UDP_Clients) 已废弃，明确要求使用网站客户端登记，不再需要额外编辑 wiki。
- OpenSubtitles：`FushiPlayer` consumer 175703；免费模式，允许默认匿名下载，未启用开发额度模式。匿名默认额度与个人登录额度不同，应用身份不能代替用户账号。
- TMDB / DanDanPlay 只核实了 GitHub Actions secret 名称和注入代码，未读取密钥值，也未重复申请。

`anidb_app_client.dart` 只包含注册的非敏感应用身份。个人账号密码仍从用户偏好读取，内置应用身份不能令空用户凭据通过登录配置判据。自定义客户端按完整 name/version 对覆盖；清空自定义名称恢复内置身份，不混合两个客户端的版本。

OpenSubtitles 密钥值不进入仓库或文档，tracked 默认文件为空，由共享 `provide-baked-secrets` action 在构建时写入。用户 key 覆盖优先，序列化只保留用户输入，不导出内置 key；无配置或未启用状态保持原样，不因内置 key 而自动发起网络请求。

内置 OpenSubtitles key 仅用于官方 HTTPS `api.opensubtitles.com:443/api/v1`，自定义服务器须填写自己的 key，避免把应用凭据发送给其他服务器。本轮已准备好构建注入；新建 GitHub Actions Secret 的操作仍待用户确认，不视为已配置完成。

## 新手教程与视频提醒

新手功能选择新增一个「在线服务（可选）」配置能力，默认不勾选。选中才加入总览步骤，不产生多个连续步骤；勾选、跳过和撤选均不修改账号或任何服务开关。

总览区分个人账号、API key、无需注册、已内置应用凭据、当前构建未注入、自建服务器。每项提供真实官方入口，配置动作复用原在线服务设置。云备份、Anki仍保留各自原有设置域，不迁移表单。

视频首页、系列、全部视频共用一个轻量横幅，介绍 AniDB、Jimaku、OpenSubtitles 的可选能力，提供总览、设置、永久关闭。永久关闭键为 `video_online_services_setup_dismissed`，通过 PreferencesRepository 的独立写入/通知入口保存，不修改服务开关和凭据；ProfileKeys 排除该键，切换学习 Profile 不复活提示。所有已挂载的视频视图监听同一偏好，关闭后立即同步隐藏。

## 验证

定向覆盖默认不选/步骤裁剪、总览注册与设置出口、应用身份不能替代用户登录、自定义身份完整覆盖、横幅窄屏和重建、跨视图关闭、偏好重载持久化、OpenSubtitles fallback/用户覆盖/序列化/禁用门，以及所有构建调用的 secret 传递。

2026-09-07：上述定向批次 154 项全部通过，`flutter analyze` 为 0 issue；另运行中文总览与窄屏横幅渲染测试 1 项通过，并检查实际生成的截图。`git diff --check` 通过。

没有发布构建或替换安装版；不把控件测试当作真实设备安装验证。API consumer 创建成功与真实下载能力/付费额度也分别记录。
