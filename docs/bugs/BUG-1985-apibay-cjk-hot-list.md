## BUG-1985 · apibay 把 CJK 查询退化为热门榜
- **报告**：2026-08-31（用户：搜索 `薬屋のひとりごと 第2期` 却出现 Ludwig、Fallout、Silo 等无关热门剧集）
- **真实性**：✅ 真 bug — 直接请求 apibay 的 TV 分类复现：CJK 查询在 208/205 均返回固定 100 条当前热门剧集，而罗马字 `Kusuriya no Hitorigoto` 返回 28/19 条相关结果。`fushi/lib/src/media/torrent/public_video_index_provider.dart:119-132` 原先把任意非空 `effectiveQuery` 原样交给 apibay，未验证该索引器是否能表达查询。
- **[x] ① 已修复** — 公共综合索引器查询统一经过 `publicVideoIndexSearchQuery`：可表达的查询原样保留；媒体自身的 CJK 标题只允许降级到同一元数据中的拉丁别名；用户另行手输且没有可信别名的 CJK 查询在传输前判 unsupported，绝不请求热门榜。apibay 与 Knaben 共用该边界，Nyaa/Torznab 不受影响（本分支提交）。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/public_video_index_client_test.dart` 的三条 BUG-1985 用例按真实字段关系覆盖：中文展示标题 + 日文原名能够解析出罗马字别名、apibay 真正收到罗马字 query、无可信别名时零 HTTP 调用并返回 unsupported；日文与中文不靠字符类别强行判等。
- **审查补修**（同一 PR 内，三条致命 + 过度拦截）：
  - **Knaben 被无理由拉进同一条边界 = 纯功能删除**。它的 `search_type: '100%'` 是
    硬标题过滤（`public_video_index_client.dart` 那条注释正是当年修同款症状留下
    的：`score` 会把 query 当权重提示返回无关热门，`100%` 才是「标题必须含关键
    词」），对 CJK 查询返回的是**正确的 0 条**，不是热门榜。原改动按「两家都在
    这个文件里」共用边界，恰恰是要避免的特例分支；删掉的正是 Knaben 相对 apibay
    的价值。已恢复原样透传，按能力分流。
  - **`unsupported` 不再表达成 provider failure，改成「未参与」**（零条 +
    `successfulProviderCount: 0`，落进既有的 `hasNoActiveProvider` 第三态）。
    表达成 failure 有两个真实后果：① 订阅 / 下载流水线把 provider failure 直接
    `throw`，而这两条路径重建 `VideoMediaReference` 时**结构上拿不到 aliases**
    （订阅行与 job 都不持久化别名），于是 CJK 标题的订阅每一轮定时任务必然抛、
    永不自愈——「单来源配额 = 自杀开关」的形状；② UI 侧 `ExternalProviderFailureKind`
    全仓没有一处按值分支、`failure.message` 也从不进任何 Text，所以 unsupported 与
    超时/限流完全等价：用户看到「加载失败 + 重试」，而重试永远不可能成功，唯一
    可行动作（换罗马字标题）拿不到。
  - **判据从「有 ASCII 字母数字 且 不含 CJK」换成「有拉丁词，或整条纯 ASCII」**
    （共享到 `lib/src/media/torrent/search_query_script.dart`）。旧判据两头都错：
    含一个汉字就整条拦，把 `Fate/stay night 劇場版` 这类混排误杀（apibay 对它并
    不退化，有拉丁词可匹配），**实现范围大于实测证据范围**；而 `[A-Za-z0-9]` 又把
    西里尔 / 希腊 / 泰文 / 阿拉伯文一并判成「不可搜」，是「非拉丁 = 不可搜」的反向
    假设，同时半角片假名 `ﾎﾟｹﾓﾝ`、Hangul 兼容字母漏在区段外照旧触发原 bug。
    另注意报告里那条真实用例 `薬屋のひとりごと 第2期` **含一个 ASCII `2`**——按
    「有字母数字」判它反而是「可搜」的，旧判据全靠 CJK 排除才拦住。
  - **`_normalizedPublicIndexTitle` 补全角 ASCII 折半角**：`第２期` 与 `第2期` 不归一
    的话，「这条查询等于媒体自己的标题吗」会因为用户从别处粘来全角数字而失配，
    别名降级白做。
  - 四条补修各做了变异实测（判据退回旧形状 / Knaben 重新入门 / 去掉全角折叠 /
    改回 failure）。其中「判据退回旧形状」第一次**没红**——因为新用例只测了共享
    原语没打 provider 路径，补了走 `publicVideoIndexSearchQuery` 的混排用例才真红。
- **已知欠账**：
  - **订阅 / 下载 job 不持久化 `aliases` / `originalTitle`**，所以这条别名降级在自动化
    路径上结构性拿不到别名。透传需要改 schema，超出本 PR。当前靠「未参与」语义
    保证它至少不抛、不自杀。
  - **未与 `preferredNyaaSearchQueries` 合并判据**，这是**有意**的：那边是「按书写系统
    分桶决定查询顺序」（Nyaa 两种标题都索引），这边是「这个站能不能表达这条查询」
    （apibay 只索引拉丁标题）。同名不同概念，强行合并会在零证据的情况下改变 Nyaa
    的查询顺序。共享的只有底层原语 `hasLatinWord` / `isPureAscii`。
- **备注**：第一次定向测试被 pdfium GitHub 资产下载超时阻断于用例前；临时为测试进程接入本机代理后 15 条测试通过。Windows 真 app 原始搜索路径待复测。
