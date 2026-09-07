# MAL/TMDB 作品资料与 AniDB 文件识别

用户在视频工作流重做之后明确调整：MAL 为主，TMDB 兜底，同时 AniDB 必须具备真正的哈希识别。此前 AniDB 唯一主资料源约束已同步更新到 CLAUDE.md / AGENTS.md。

## 资料策略

- 新作品优先查 MAL，实际传输使用 Jikan v4 公共只读接口，持久 provider 名为 `mal`。
- MAL 严格匹配成功后保留其已有标题、简介和评分；缺图、演职员或分集信息才尝试严格匹配 TMDB 补缺。MAL 查无/不可用允许 TMDB 成为本次主身份；歧义仍需人工确认。
- 手动 MAL ID 不分 movie/tv 命名空间，由源返回真实类型；TMDB 必须区分电影/电视剧。明确 ID 失败不会自动改绑其它作品。
- MAL 空季、空集或少于已声明集数的响应不是权威删除依据，不会清掉已有完整季集记录。
- MAL 的原始文本不提供按任意界面语言翻译的保证。语言设置用于 TMDB 兜底和补充资料。
- 发现 feed 仍独立；发现详情和下载/订阅快照优先沿用已有 MAL ID，其次使用类型明确的 TMDB ID，不再额外做 AniDB 标题确认。

## AniDB 文件识别

在在线服务设置开启「通过 AniDB ED2K 识别文件」，填写自己的 AniDB 账号和密码。应用已内置注册客户端 `fushiplayer` v1；自定义客户端名称/正整数版本仅供覆盖使用。默认关闭；配置缺失时不读文件、不发 AUTH，任务说明不可用。登记及可选引导见[在线服务配置](2026-09-07-online-services-setup.md)。

当前在作品尚未有受支持的规范绑定/明确 ID 时进行文件识别。已有明确绑定继续受保护，手动匹配优先。按文件夹组织的普通视频来源不进入作品刮削与哈希识别。

1. 在 worker isolate 内以 64 KiB 缓冲读真实文件，计算 9,728,000 字节分块 MD4/ED2K。
2. 使用 AniDB/AVDump3 red 变体；整块倍数同时计算 blue 兼容哈希，仅主哈希返回未收录时尝试另一变体。
3. UDP AUTH 后发送 FILE 的文件大小和 ED2K，记录真正返回的 fileId、animeId、episodeId、原生 episodeNumber，以及实际命中的哈希。
4. 通过 Fribb Anime-Mapping 的明确 AniDB→MAL 映射绑定作品；多映射或同组命中不同 AniDB 作品时停止自动决定。无映射时只能用 AniDB 返回的真实标题继续严格资料匹配。

AniDB 原生集号是识别证据，不会未经验证直接转换为 MAL/TMDB 季集号。未知分集文件可保存作品身份，但不会伪造跨站分集绑定。任务结果区分「文件哈希已命中」与「MAL 映射未确定」。

## 运行边界

- UDP 默认 `api.anidb.net:9000`，客户端固定本地端口19000、全 app isolate 共享节流、会话串行和服务端冷却。关闭会取消未完成接收，并让后继客户端等待固定端口释放。
- AniDB UDP 登录默认不加密，设置中明确提示仅在可信网络启用。账号/密码不进入日志，密码不被 trim；两项凭据由统一脱敏规则排除于备份/Profile分享并在恢复时本机保留。
- 不上传视频内容；文件查询只提交大小与哈希。哈希计算前后及身份返回前检查文件状态；文件变化不会被报告为成功匹配。
- 取消必须等待 worker 关闭文件句柄，避免 Windows 文件一直被占用。完整哈希采用有界内存缓存，按路径、大小、mtime、changedAt失效。
- Jikan 每秒最多启动一个请求，带 TTL/去重缓存和429冷却。Fribb 映射按24小时缓存并在JSON解码前限制体积；网络响应缓冲仍由共享HTTP层管理。

## 验证

自动测试覆盖官方 MD4/ED2K 向量及整块边界、真实worker取消与文件变动、真实 loopback UDP AUTH/FILE/tag/LOGOUT与固定端口接棒、备用哈希审计、映射歧义、MAL优先/TMDB兜底、空分集非权威保护、手动ID锁源和下载身份传递。

本地集中批次317条通过、相邻界面批次57条通过；最后的存量身份/解析/下载/配置兼容批次155条通过，Flutter analyze退出0、0 issue。各批次有重叠，不能相加当作唯一测试数。实际MAL只读探针取得作品详情，但分集接口返回HTTP504，整次在线探针未通过；此状态不能记为在线全链路成功。没有使用用户凭据登录真实AniDB服务器，没有做安装版设备E2E，也没有运行全仓Flutter测试或PR CI。

## 协议与数据参考

- [Jikan REST v4](https://docs.api.jikan.moe/)（MAL 数据接口）
- [AniDB UDP API](https://wiki.anidb.net/UDP_API_Definition)（AUTH/FILE、掩码、转义与限流）
- [AniDB ED2K](https://wiki.anidb.net/Ed2k-hash) 与 [AVDump3 ED2K 实现](https://github.com/DvdKhl/AVDump3/blob/master/AVDump3Lib/Processing/HashAlgorithms/Ed2kHashAlgorithm.cs)
- [Fribb Anime-Mapping](https://github.com/Fribb/anime-lists)（仅明确ID映射，不作为额外作品资料源）
