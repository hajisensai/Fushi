## BUG-1985 · apibay 把 CJK 查询退化为热门榜
- **报告**：2026-08-31（用户：搜索 `薬屋のひとりごと 第2期` 却出现 Ludwig、Fallout、Silo 等无关热门剧集）
- **真实性**：✅ 真 bug — 直接请求 apibay 的 TV 分类复现：CJK 查询在 208/205 均返回固定 100 条当前热门剧集，而罗马字 `Kusuriya no Hitorigoto` 返回 28/19 条相关结果。`fushi/lib/src/media/torrent/public_video_index_provider.dart:119-132` 原先把任意非空 `effectiveQuery` 原样交给 apibay，未验证该索引器是否能表达查询。
- **[x] ① 已修复** — 公共综合索引器查询统一经过 `publicVideoIndexSearchQuery`：可表达的查询原样保留；媒体自身的 CJK 标题只允许降级到同一元数据中的拉丁别名；用户另行手输且没有可信别名的 CJK 查询在传输前判 unsupported，绝不请求热门榜。apibay 与 Knaben 共用该边界，Nyaa/Torznab 不受影响（本分支提交）。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/public_video_index_client_test.dart` 的三条 BUG-1985 用例按真实字段关系覆盖：中文展示标题 + 日文原名能够解析出罗马字别名、apibay 真正收到罗马字 query、无可信别名时零 HTTP 调用并返回 unsupported；日文与中文不靠字符类别强行判等。
- **备注**：第一次定向测试被 pdfium GitHub 资产下载超时阻断于用例前；临时为测试进程接入本机代理后 15 条测试通过。Windows 真 app 原始搜索路径待复测。
