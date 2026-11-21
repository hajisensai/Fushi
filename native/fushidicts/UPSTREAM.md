# hoshidicts 上游同步基线（UPSTREAM baseline）

> 本文件是 `native/fushidicts/` C++ 引擎相对上游的**唯一基线真相源**。
> 每次从上游同步代码后更新「同步基线」与「已直抄/已合并的上游 commit」两节，
> 避免下次同步又对着几百行盲 diff。

## 上游仓库

- Repo: **Manhhao/hoshidicts** — https://github.com/Manhhao/hoshidicts
- 主线分支: `origin/main`
- 忽略的上游分支:
  - `origin/c-bindings`：Hibiki 已有自研 FFI/JNI 桥（见下「本地改动」），不采用上游 C bindings。
  - `origin/kanji` / `origin/main-mit`：非主线，按需评估。

## 同步基线

- **上游 `origin/main` 当前 tip**（批4 同步参照，2026-08-16）：`8993838`（"train zstd dict on import"）。
- **2026-11-16 性能批的评估参照 tip**：`34074bd`（性能提交见「2026-11 性能批」，其中 5 条功能提交见「2026-11 功能同步」，`fcea33f` 在格式批移植，`1c230f3` 未评估）。
- **Hibiki 批4 同步后所含的上游主线 commit**：截至 `8993838`，但**跳过**了主线上的若干提交（见「批4 明确跳过/暂缓」）。
- Hibiki 是 hoshidicts 的**深度 fork**：在上游主线 `2dd5199`（"count freq and pitch entries"，2026-05-16）一带分叉后，
  额外吸收了 sibling commit `feb48f5`（"add detected_type to ImportResult"，非 origin/main 主线，分叉自 `2dd5199`），
  并自研了大量上游没有的功能（见「Hibiki 本地改动清单」）。因此上游与 Hibiki **不是线性 pull 关系，是双向 merge / cherry-pick**。

## 本轮（TODO-621 批1）直抄的上游 commit

| 上游 commit | 标题 | 落到 Hibiki 的文件 | 风险 |
|---|---|---|---|
| `3448d6d` | Accept numeric Yomitan term scores (#14) | `fushidicts_src/json/yomitan_parser.hpp`（`Term::score` `int`→`double`；`Tag::score` 不动） | 零盘格式风险（写盘不含 score） |
| `4975788` | consider all freq values when sorting within dict | `fushidicts_src/lookup.cpp`（`get_freq_value_for_dict`→`get_freq_values_for_dict` 返 `vector<int>` + 调用点） | 纯查询期排序，不碰 importer/写盘 |
| `1a34a59` | fix swift compilation on c++23 | `fushidicts_include/hoshidicts/query.hpp` + `fushidicts_src/query.cpp`（`Dictionary` pimpl 5 个特殊成员声明+定义） | 仅编译期，5 平台受益 |

> 上述三处 apply 前已逐字节确认 Hibiki 仍是上游旧版（OLD），diff 与上游对应 commit 一致（除 Hibiki 本地上下文如 `fushi::fs_path`）。

## 历史遗留记账修正（批4 复核）

批1 时列为「未同步/待评估」的两条，实际**早已在 Hibiki 落地**（当时忘了回写本文件）：

| 上游 commit | 标题 | Hibiki 实际状态 |
|---|---|---|
| `2d4f2a2` | add normalization processors（NFKC） | ✅ 已落地：utf8proc v2.11.3 vendored 进 `fushidicts_external/utf8proc/`，NFKC 处理器在 `text_processor.cpp` 日语链 |
| `e7dfdea` | add kanji standardization（异体字标准化） | ✅ 已落地（非直抄）：绕开 C++23 `#embed`，用离线预生成表 `kanji_standardization_data.{h,cpp}`（`tool/native_gen/gen_kanji_standardization.py`，kanji-processor pin 452cc2db，2122 条）。上游后来的 `4ffbffb`（replace #embed，提交生成的 C 数组源文件）自行收敛到与 Hibiki 等价的方案——数据集逐条同源，无需再动 |
| `1198201` | fix swift build | 仅 SwiftPM，跳过（不变） |

## 批4（2026-08-17）同步：`3448d6d`..`8993838`

**已移植（直抄或适配，见各文件内注释）：**

| 上游 commit | 标题 | 落到 Hibiki | 方式 |
|---|---|---|---|
| `9dc93b6` | expand iteration marks（々/ゝ/ゞ 展开） | `text_processor.cpp` | 适配（standardize_kanji 上下文已本地化） |
| `ee0384b` | fullwidth numbers → kanji（２→二） | `text_processor.cpp` | 直抄 |
| `aaf75c9` | collapseEmphaticSequences（っっ/ーー 折叠） | `text_processor.cpp`（插在假名转换后，对齐上游链序） | 直抄 |
| `1cb9b4b` | normalize kana width before script conversion | `text_processor.cpp`（NFKC 提到日语链首；半角片假名 ﾒｶﾞﾈ 修复） | 直抄 |
| `909c854`（仅 revert 部分） | revert `4975788` freq 向量比较 | `lookup.cpp`（回到单一最小值比较；score 排序+格式 bump 部分**未采纳**，见下） | 直抄 |
| `d4183d4` | bloom/hash size 校验 + flush before unmap + 删 bloom migration | `bloom.{hpp,cpp}`（size 校验，置空降级不拒载）、`memory.cpp`（flush）、`query.cpp`（删 migration，消掉穿 FFI 的 throw；hash 侧保留 fork 自研 BUG-1303 clamp，不用上游拒载版） | 适配 |
| `01630e8` | freq 嵌套 object 解析收紧 | `yomitan_parser.cpp`（optional display_value + error_on_missing_keys，对齐 flat 路径既有风格） | 直抄 |
| `79c55c2`（parser 先行部分） | pitch accent spec：position 收 `variant<int,string>` | `yomitan_parser.cpp`（pattern 字符串位不再让整条 meta 记录解析失败；nasal/devoice/pattern 的结构化输出 + FFI/UI 二期另议） | 部分适配 |
| `8993838` | train zstd dict on import | `importer.cpp`（train_zstd_dict + CDict 压缩 term glossary + 落盘 `dict.zstd`）、`query.cpp`（DDict + thread_local DCtx 解压）——引入 **v2 格式阶梯**（见下） | 适配 |
| `c5d8c6d`（仅 1 行） | `<climits>` include 修复 | `lookup.cpp`（fork 同样裸用 INT_MAX） | 直抄 |
| `64afa2f`（仅借鉴 stats 能力） | 上游 kanji dicts | kanji 记录 v2 追加 stats 段（见下）；上游 kanji 实现本体**跳过**（与 fork 自研 kanji 同 type byte 两套布局，互不兼容，fork 版能力更强） | 借鉴 |
| `909c854`（score 部分，批4 二轮补齐） | term score 落盘 + 排序 | v2 term 记录在 term_tags 后追加 i32 score（v2 未发布窗口内折入，免再升 v3）；`query.cpp` 版本门控读取 + 合并取 max；`lookup.cpp` 比较器 freq 档后 score 降序。score 不出 FFI（纯 native 排序信号） | 适配 |
| `79c55c2`（结构化部分，批4 二轮补齐） | Pitch{position,pattern,nasal,devoice} 完整规格 | `ParsedAccent`/`Pitch` 结构贯通 parser→query；pattern 出 FFI（`FfiPitch.patterns` 平行数组）→Dart（`FushiPitchEntry.patterns`）→popup JSON（`"patterns"`）→JS 渲染 `[pattern]` 文本项 + 制卡类别字段并入 pattern 名；popup_json/Dart 镜像 pkey 折 pattern（IPA 折 key 同型坑）。nasal/devoice 收在 native `Pitch` 数据模型，文本形态 UI 无渲染语义、暂不出 FFI | 适配 |
| `bc62d2b`（批4 二轮补齐） | lookup 排序选项 | `LookupOptions{frequency_dictionary, frequency_order}` + `Lookup::lookup` 第 4 参（默认 Auto 零行为变化，排序在截断前）；新 FFI 导出 `fushidicts_lookup_with_options`（老导出原样保留）+ Dart `lookup()` 可选参数。设置 UI 是产品决策，管道先行 | 适配 |
| `86c6e2f`（批4 二轮补齐） | primary_reading 优先 | `LookupOptions.primary_reading`，比较器最前档；同上管道贯通 | 直抄（叠在 options 上） |

**磁盘格式 v2（`.fushidicts_2`，fork 首个版本阶梯）：**
- `import_yomitan` 产出 `.fushidicts_2`；`write_simple_dict`（MDX/StarDict/DSL）仍产 `.fushidicts_1`。
- 读侧 `dict_format_version()`（query.cpp，委托 `util/dict_marker.hpp` 单一真相源）：`.fushidicts_3`→文件体记的记录布局版本（"2" / "1"，其余→不加载），`.fushidicts_2`→2，`.fushidicts_1`/`.hoshidicts_1`（改名前存量，冻结只读）→1，无 marker→不加载。
- **`.fushidicts_3`（key.index 索引，拍板台 pr3554）**：索引写成 key.index（不再有 hash.table / bloom.filter）的词典一律写 `.fushidicts_3`，文件体是记录布局版本；装不进 key.index 退回旧式索引的仍写 `.fushidicts_2` / `.fushidicts_1`。存量升级（`upgrade.cpp`）提交 key.index 后先写新标记、落盘目录项，再删旧标记。旧引擎读 v3 盘＝整目录不加载（降级要重导，不会静默查不到词）。宿主每次启动只调 `fushidicts_tidy_dictionary`（只检查 + 清理，旧式词典不改写、报待升级），用户同意后才调 `fushidicts_upgrade_dictionary`。
- v2 增量：① kanji 记录尾部追加 stats 段 `[u8 count]([u8 klen][k][u16 vlen][v])*`（radical/strokes 之外全保留，JLPT/grade 等；S0 契约注释在 importer.cpp）；② term 记录尾部追加 `[i32 score]`（Yomitan 排序信号，多记录合并取 max）；③ term glossary 可能用训练字典压缩，`dict.zstd` 存在才挂 DDict（训练样本不足时不写，退普通压缩）。
- 兼容矩阵：新引擎读 v1 老盘**完全不变**；旧引擎读 v2 盘＝整目录不加载（降级后新导入词典不可见，不毁数据，重导可救）。kanji meanings / meta 记录恒普通 zstd 帧，不吃训练字典。
- FFI：`FfiKanjiResult` 追加 `stat_keys/stat_values/stat_count`（native+Dart 同 commit 镜像，照 918744d transcriptions 先例双层 malloc/free）；其余 ABI 零变化。
- 守卫：`tests/format_v2_upstream_sync_test.cpp`（v2 marker/stats 读回/marker 拒载/bloom 截断降级/zstd 往返/pitch pattern 容忍）+ `tests/text_processor_test.cpp` 新增 processor 用例。

**批4 明确跳过 / 剩余项（批4 二轮已把「没坏处」的暂缓项全部补齐；下表为终态）：**

| 上游 commit | 标题 | 处置 | 理由/重估条件 |
|---|---|---|---|
| `702dcc5` | build summary on import | 跳过 | 改写 index.json/删 styles.css，冲突 fork 读侧契约（弹窗样式丢失）+ 破坏 FfiImportResult；如需导入元数据留档，fork 自己加 sidecar |
| `64afa2f` | kanji dicts（实现本体） | 跳过 | 与 fork 自研 kanji 同 type byte 两套布局，换=毁存量；stats 能力已借鉴进 v2 |
| `88b073d` | c bindings 合入主线 | 跳过（政策不变） | fork 自研 FFI 桥等效且 errors 向量信息更全；原「忽略 c-bindings 分支」政策改述为「已合主线，仍跳过」 |
| `c5d8c6d`（submodule bump 部分） | 7 个依赖 pin 升级 | 不做（有真实坏处） | fork 是 vendored 实拷贝，7 库齐升有隐性构建/行为回归风险、收益近零（zstd 1.6.0 / utf8proc v2.11.3 均不落后关键功能）；单库确有需要时按需单独 vendor |
| `f9aa482` / `7bfdc8c` / `32b8ce5` / `e1a8c1c` / `6240e06` / `f151dbb` | submodule URL / cli+benchmark 开关 / swift cli / benchmark 修复×2 / readme | 跳过 | fork 无 submodule / 无 cli/benchmark target / 不用 SwiftPM |
| `d6c9ea2` | use native filesystem paths | 跳过 | 已被 fork 自研 `fushi::fs_path`/`to_wide`（`util/fs_utf8.hpp` + `memory.cpp` W 系 API + `win_utf8_import_test`）等价覆盖 |
| `e88430d` | MSVC /utf-8 | 跳过 | fork `CMakeLists.txt` 已有全局 `/utf-8 /Zc:__cplusplus /permissive-`，覆盖面更大 |

真正的后续（非上游同步，产品决策）：排序选项/primary_reading 的设置 UI 与弹窗内链消费方；pitch nasal/devoice 的图形化渲染（数据模型已收全）。

## 2026-11 性能批：评估上游 `9cabc17`..`c28a687` 的性能提交 + 本地查词提速

上游 tip（评估参照，2026-11-16）：`34074bd`。本批**只评估性能相关提交**；同一区间里的功能
提交 `30ad52f` 去片假名中点、`3f0c2d9`、`ad0be91` 强调っ / 片假名边界、`e2a007f` 歴史的仮名遣い、
`8e89a5d` -やしない 见下「2026-11 功能同步」；`fcea33f` 数字串频率已在格式批移植（见下表）；
`1c230f3` 原地增删词典仍未评估，留给下一次功能同步。

| 上游 commit | 标题 | 处置 | 说明 |
|---|---|---|---|
| `9cabc17` | perf: reduce Japanese text preprocessing overhead (#34) | **采纳思路、重写** | `text_processor::process`：处理器表进程内只建一次、变体表 `std::map` → 排序向量、各处理器 `reserve`。fork 多走一步：「不改写」那一档不占 option 编号（不调用也不拷贝），一轮没产出新变体就不重排。变体顺序仍是码点字典序（它决定 lookup 的同长度取舍，是行为的一部分）。 |
| `9daeea4` | query meta after filtering | **已等价** | fork 自 BUG-1304 起就是「过滤 / 去重后再查 freq、截断后再查 pitch」（`lookup.cpp`）。 |
| `e6af33e` | fix: read media on on demand | **已等价** | fork 的 BUG-4013：`media.bin` 不映射、按请求 `file_reader` 定位读。 |
| `2f0e5c5` | replace linear hash and bloom filter with phf | **不采纳（另做 key.index，见下节）** | 换磁盘格式：每本词典的 `hash.table` + `bloom.filter` 换成 PHF（分区 4096 字节、256 桶 pilot、8 字节 slot + 前置 blocked bloom）。它降的是**单次探测**的成本；fork 实测耗时大头是**探测次数**（一次查词约 1.85 万次逐词典探测），下面的联合过滤器把这部分直接拿掉、且不动格式。PHF 剩下的收益是索引体积约减半，代价是存量词典要现场迁移（上游 `phf::migrate` 迁完删旧文件）——迁过的词典旧版 app 打不开（降级即坏），所以单列为待决策项，不夹在本批里。2026-11 格式批改做桶式键索引 `key.index`（下节），不移植 PHF。 |
| `eb4e5dd` | preparse meta dicts during import | **已采纳（格式批，见下节）** | 导入期把 freq / pitch 的 JSON 预解析成二进制（type 3 记录）。同样是格式变更，且只有**新导入**的词典受益；fork 实测频率富化里 JSON 解析只占约三成（每次查词约 600 条、约 0.1 ms），其余是读记录的缓存未命中，已由下面的分遍预取覆盖一部分。2026-11 格式批采纳：type 3 记录布局与上游一致，另加存量词典原地重写。 |
| `c28a687` | bump format version | **不适用** | 上游为上两条把 marker 升到 `.hoshidicts_5`；fork 的格式阶梯是 `.fushidicts_1 / _2`。格式批也不升 marker：用哪种索引由目录里有没有合法 `key.index` 决定，记录类型逐条自描述（type 1 / 3 混存合法）。 |
| `fcea33f` | numeric-string frequencies | **已移植（格式批）** | 频率值是数字串（`["語","freq","123"]`）时此前整条被丢；`json/yomitan_parser.cpp parse_frequency` 先按数字读、失败再按 `quoted_num` 读。查询期（type 1）与导入期预解析（type 3）走同一函数，两种形态结果相同（`dict_upgrade_test` 的 `走る` 条目）。真实 64 本词典里没有这种条目，指纹不变。 |

**本地改动（上游没有）：**

- **联合过滤器**（`fushidicts_src/hash/union_filter.{hpp,cpp}`）：引擎里全部词典的键并进一份分块
  Bloom——键哈希选一条 64 字节缓存行，「键在词典 d 里」按（键哈希, 词典身份）在行内点 7 个位。
  一次查库读一条缓存行就对每本词典判出「肯定不在 / 可能在」，放行的才走各自 `hash.table` 的
  精确探测（各词典自己的 `bloom.filter` 不再碰）。无假阴性（由每本 `hash.table` 的全部非空槽位
  建成），假阳性约千分之一、只多付一次精确探测，所以**查词结果逐字节不变**。它是派生物：不改
  任何词典目录、存量词典不必重导；缓存文件 `union-<hash>.filter`（校验和覆盖文件头、身份列表与块区，每次装载都验；写入时不同步刷盘）放
  宿主给的缓存目录，丢了 / 坏了 / 词典集合变了就重建，身份集合是当前集合超集的旧文件可复用
  （关掉一本词典不重建）。约 2 字节 / 键（64 本、1200 万键 ≈ 24 MB，文件映射、可换出）。
  - 词典身份 = 实际在用的索引文件（`key.index` 或 `hash.table`）的大小 + 修改时间 + 首页内容 +
    记录文件大小（`hash/dict_index.cpp file_identity`），与词典在引擎里的次序无关。格式批起过滤器
    建在键的 29 位 tag 上（见下节）。
  - 生命周期：`DictionaryQuery::prepare_union_filter(cache_dir, wait)` 由宿主在装完一套词典后
    调；后台线程归引擎独占，`add_*_dict` 作废过滤器并叫停构建，引擎析构时叫停并等线程退出
    （毫秒级）——线程撑着各 `hash.table` 的映射，不收回的话「释放映射后马上删词典目录」会撞
    文件占用（BUG-1756 的形状）。建好之前查询照走各词典自己的 bloom。
  - FFI：`fushidicts_prepare_union_filter` / `fushidicts_union_filter_state`；Dart
    `FushiDicts.unionFilterCacheDirectory`（app：平台缓存目录下 `fushidicts/`；`fushi_server`：
    `tmp/fushidicts/`），三处装载路径装完即调。
- **一次查库只算一次键哈希**：`KeyProbe`（`query.cpp`）。此前每本词典各算一遍 XXH3。
- **分遍预取**（`query.cpp locate_all` + `util/prefetch.hpp`）：命中一本词典要连读
  `hash.table` 槽位 → offset 表 → 记录三处互不相邻的内存。逐本走到底是上百次缓存未命中排队；
  改成每遍只做一件事并预取下一遍的地址，各本词典的未命中同时在路上。窗口映射（32 位）下只
  预取槽位。
- **混写候选读音全程 UTF-8**（`scan/mixed_orthography.cpp reading_candidates`）：此前每个候选
  都 UTF-8 → UTF-32 → UTF-8 往返；`run_readings` 回调改返回引用，不再每次拷贝整张读音表。
- **解压不先清零**（`query.cpp decompress_glossary`）：`resize_and_overwrite`。

**实测**（`native/fushidicts/benchmark/lookup_bench`；真实装载的 64 本词典 = 51 释义 / 10 频率 /
3 音调，语料是青空文库公有领域文本节选，对每个码点位置各查一次共 1143 次，`scan 16 / max 16`；
同机交替跑、各取最好一轮的平均值；改动前后结果指纹相同）：

| 模式 | 改动前 | 改动后 | 倍数 |
|---|---|---|---|
| 弹窗查词（截断后解压释义） | 4.81 ms | 1.85 ms | 2.6× |
| `materialize = false`（不解压） | 3.88 ms | 1.02 ms | 3.8× |
| `materialize = false`、`max 1`（分词路径） | 4.15 ms | 1.07 ms | 3.9× |

过滤器首次构建约 0.8～1.1 秒（后台线程，期间查词照走旧路径），之后每次装载约 7 ms（映射 +
校验）。改动后「弹窗查词」剩余耗时里约一半是截断后那 16 条结果的 zstd 解压（每次查词约
170 帧、解出约 1 MB），已到 zstd 吞吐上限，再降要靠惰性 / 并行解压，属 API 形态变化，本批不动。

守卫：`tests/union_filter_test.cpp`（无假阴性 / 假阳性率 / 坏缓存与被改的身份列表被拒并重建 / 超集复用 / 叫停
不留半截文件 / 有无过滤器时真词典上的 lookup、query 逐字段相同 / `add_dict` 后作废 / 后台构建
就绪 / 引擎销毁后不留文件映射）+ Dart `packages/fushi_dictionary/test/union_filter_native_test.dart`。
既有的查词守卫（混写、关西、韩语、简繁、重定向、排除词典、分词批量比对）全部照过。

## 2026-11 格式批：key.index 键索引 + type 3 meta 记录 + 存量词典原地升级

接上节的联合过滤器。三件事都改磁盘格式，但**旧格式照常可读**：引擎按目录里实际有的文件选路径，
没升级的词典不受影响。

**打开词典只有一处**：`fushidicts_src/hash/dict_index.{hpp,cpp}`。`key.index` 合法且它指的记录
文件（`blobs.bin`，或 `rewritten` 时的 `blobs3.bin`）打得开 → 用它；否则退回 `hash.table` +
`bloom.filter`（损坏的 `key.index` 旁边旧文件还在时词典照常可查）；旧式也打不开时再看一次
`key.index`——装载不拿升级的锁，而升级是先提交 `key.index` 后删旧文件，「刚才没有 key.index、
转头旧文件也没了」只可能是它在这两步之间提交了。头里 `num_keys` 多过槽位数的不装载。查库、整本扫描
（`probe_dict_content`、`ensure_redirect_glossary_flag`、`redirect_glossary` 扫描）、联合过滤器
来源都经它，不再各自拼文件名。

- **key.index**（`hash/key_index.{hpp,cpp}`，布局沿用 `ce12a7aa7b0` 未改）：64 字节一桶 8 个
  槽位，每槽 29 位 tag + 溢出 / 占用 / single 三个标志 + 32 位 offset；每个键一个主桶一个备桶，
  主桶满了才进备桶并给主桶打溢出位。`single` 的键 offset 直接指记录（不写 offset 表），多记录
  的键指 offset 表。offset 超 32 位时 `build_to_file` 拒绝，导入退回旧式。
  - **与上游 PHF 的区别**：不是完美哈希，查一个键读一条缓存行（溢出时两条）；不需要前置
    bloom（没有联合过滤器时直接探主桶，代价同样是一条缓存行）；构建是线性的，不需要 pilot
    搜索。
  - **核对**：tag 只有 29 位，候选可能是别的键。`locate` / `locate_all` 对每个候选读第一条
    记录的键（term 的 expression 或 reading，其他类型的首串）核对，主桶都不中且有溢出位才看
    备桶，所以无假阴性；旧式 `hash.table` 也一样核对（此前 64 位哈希相等就当命中）。
  - **构建端保证查找路径上没有第二个同 tag 的键**（同一桶里不放两个同 tag 的键；住在备桶
    的键，它的主桶里也没有同 tag 的键）。撞上了就把桶数加一重排，最多 8 次，仍不行则
    `build_to_file` 返回 false（导入退回旧式 / 升级报不适用）。有了它，「只核对第一条记录」
    是精确的：两个同 tag 的键共用首记录（一条 term 的 expression 与 reading）也不会查错。
  - **联合过滤器**改建在 tag 上：tag 选块，块内位由（tag, 词典身份）决定；`kVersion = 2`、
    `kLayout` 带 tag 位数，旧缓存一律被拒并重建。key.index 来源直接枚举 tag、有确切键数。
- **type 3 meta 记录**（`json/meta_record.{hpp,cpp}`）：布局同上游 `eb4e5dd`（freq：reading +
  i32 值 + 显示串；pitch：reading + 若干 {位置, pattern, nasal[], devoice[]}；ipa：reading +
  若干串）。导入期解析失败的条目、长度超 u16 的条目留 type 1；查询期两种类型走同一套解析结果
  结构，结果逐字段相同。
- **原地升级**（`fushidicts_src/upgrade.cpp`、`fushidicts_include/fushidicts/upgrade.hpp`；
  C ABI `fushidicts_upgrade_dictionary(dir, allow_meta_rewrite)` 经 `ffi_guard`，返回
  -1 失败 / 0 已是最新 / 1 已升级 / 2 不适用）：从 `hash.table` 读出全部键，写新 `key.index`；
  `allow_meta_rewrite` 且全部记录都是 type 1 时把记录重写成 `blobs3.bin`（能解析的转 type 3）并
  写 `rewritten` 的 key.index。**不修改、不截断、不覆盖任何在用的文件**：新文件写到唯一命名的
  临时文件、落盘（`memory::sync_file`：`FlushFileBuffers` / `F_FULLFSYNC` / `fsync`）再改名，
  改名成 `key.index` 是提交点；之后把目录项落盘（`memory::sync_directory`）再删旧文件
  （Windows 上引擎还映射着就删不掉，留到下一次调用再删；常态没有旧文件时不碰磁盘）。遗留的
  临时文件超过 10 分钟才清，孤儿 `blobs3.bin` 被清掉。
  - **同一本词典的升级跨进程、跨线程串行化**：整个调用持有导入标记文件上的独占锁
    （`memory::file_lock`：POSIX `flock`、Windows `LockFileEx` 锁文件末尾之外的一个字节，
    阻塞等待），拿到锁后再看目录现状。没有这把锁时两个调用交错会互相删掉对方刚提交的
    `key.index`（或把它改回指向已删除的 `blobs.bin`），词典从此打不开——审查时在 Mac 与
    Windows 上都复现过。
  - `add_dict` 从不升级（升级是宿主显式调的一次性动作）。offset 超 32 位、或一个键都没有的
    词典返回不适用。
- **宿主接线**：`FushiDicts.upgradeDictionaryFormats`（逐本在后台 isolate 跑，借用账本与删 /
  覆盖词典串行，同 `ensureRedirectFlags`）。app 启动首帧后由
  `DictionaryFormatUpgradeCoordinator` 编排：先不占词典写锁逐本静默检查（常态启动到此为止）；
  确有词典升级且后面还有，才占写锁、在词典页状态行显示「正在升级词典格式（n/总数）」；升级过
  就影子引擎重载、等旧引擎放手后静默补跑一遍清旧文件。`fushi_server` 在首次装载前同步升级。
- 新导入默认写 key.index + type 3；`FUSHIDICTS_LEGACY_INDEX=1` 只给测试用，强制旧式。

**风险 / 已知限制：**

- **降级即坏**：升级过 / 新导入的词典没有 `hash.table`，旧版 app 打不开；`rewritten` 的词典连
  `blobs.bin` 也没有。
- 联合过滤器因 tag 截断多出约 n/2^29 的假阳性（n 为全部键数），只多一次精确探测。
- `key.index` / `blobs3.bin` 没有校验和：防的是「没写全」（改名前落盘），不防介质上的位翻转
  ——与 `hash.table` / `blobs.bin` 一向的口径相同。
- Windows 上查词弹窗是独立进程、也映射着词典文件：它没重载之前，补跑那一遍删不掉旧文件，
  留到下次启动清（只是多占一阵磁盘，不影响查词）。

**实测**（同上节的 64 本词典与语料；副本在 `D:/hibiki-tmp/dictfmt3/`，原目录只读；三种状态
——基线 exe 读原目录、新 exe 读未升级副本、新 exe 读升级后副本——三种模式的结果指纹全部
等于基线 `5966df6ff1a00285` / `017aac1a38ae2360` / `e56884189c8a2956`）：

- 升级 64 本（全新副本，含改名前落盘）：0 失败，合计 5.3 秒（最慢 BCCWJ 频率 0.94 秒，其次
  两本各约 0.47 秒）；再调一遍 64 本全部「已是最新」合计 64 ms。索引 303.0 MB → 115.1 MB
  （-62%），记录文件 1839.0 MB → 1694.0 MB（meta 重写，-8%），词典目录合计 2148 MB → 1815 MB。
- 查词（同机交替 3 轮、每轮每个配置 10 遍取 warm 最好的平均值，再取 3 轮最好；测时机器上
  还开着别的程序，绝对值比上节略高，三个配置交替跑、相对差可比）：

  | 模式 | 基线（原目录） | 新代码 + 未升级 | 新代码 + 升级后 |
  |---|---|---|---|
  | 弹窗查词 | 1.755 ms | 1.794 ms（+2.2%） | 1.714 ms（-2.3%） |
  | `materialize = false` | 1.014 ms | 1.035 ms（+2.1%） | 0.959 ms（-5.4%） |
  | `materialize = false`、`max 1` | 0.999 ms | 1.028 ms（+2.9%） | 0.953 ms（-4.6%） |

  未升级词典多出的 2～3% 是旧式路径新增的记录键核对（每个命中多读一次记录头）。
- 联合过滤器首次构建（文件缓存已热）：未升级 545 ms、升级后 430 ms；之后每次装载 5～6 ms；
  缓存文件都是 24,471,488 字节（块数由键数估计取整决定，键数相同）。

守卫：`tests/dict_upgrade_test.cpp`（旧式 / 旧式+升级 / 只换索引 / 新式与混装四种状态下
lookup、query、query_kanji 逐字段相同，有无联合过滤器都比；A 的哈希指向 B 的记录必须查不到、
主桶塞满同 tag 假候选时真键在备桶必须查得到、旧式表同样核对；升级幂等、遗留临时文件 / 孤儿
`blobs3.bin`、key.index 损坏回退、引擎装着词典时升级、新引擎装着升级后的词典时补跑清理；
手写索引：主桶只有溢出位而真键在备桶、主桶无溢出位则不看备桶、tag 相符但 offset 越界、
`num_keys` 超槽位数；并发：别人持锁时升级必须等、4 线程混合参数同时升级同一批词典后每本
恰好一个调用报已升级且结果与旧式相同），`tests/key_index_test.cpp`（同 tag 的键可分开时
分开、分不开时拒绝构建），`union_filter_test`
（新增 key.index 来源与混装来源；引擎层新式 / 旧式各跑一遍），`hash_truncated_table_guard_test`
（key.index 截断 / 桶数被改 / 全 0xFF 被拒）。以上与受影响的既有测试在
`FUSHIDICTS_BLOB_WINDOWED=1` 下同样通过。

## 2026-11 功能同步：上游 `30ad52f` / `3f0c2d9` / `ad0be91` / `e2a007f` / `8e89a5d`

评估参照仍是上游 `34074bd`。上游的变形规则写在 `src/deinflector.cpp`（C++），fork 的规则数据在
`fushi/assets/transforms/ja.json`（导自 Yomitan，与上游规则表大体同源），所以规则类提交是**把上游
新增的规则逐条并进 ja.json**（插在上游组内的前驱规则之后；新组的说明文字原样照抄，中文译文进
`fushi/assets/transforms/i18n/zh-CN.json`）。

| 上游 commit | 标题 | 处置 | 说明 |
|---|---|---|---|
| `30ad52f` | processor to strip katakana middle dots | **采纳** | `text_processor.cpp strip_middle_dots`，挂在日语链尾（上游链序）。半角 `･` 经链首 NFKC 归一成 `・` 后同样被删。 |
| `3f0c2d9` | drop middle dots only if they are actually between two characters | **改写移植** | 上游代码只保留串尾的点；fork 按提交说明的意图把串首的点也保留（只删夹在两个字符之间的点），否则从点上开始的查询会把点算进同一词条的匹配长度。 |
| `ad0be91` | fix: lookup matches misread emphatic っ and katakana boundaries (#37) | **采纳（含一处改写）** | 四件事：① `くって → い`（`-て` 组）进 ja.json；② 变形改写量上限 `max_rewrite`：变形不得跨过原文里的中点 / 被折叠掉的っ（`text_processor.cpp max_rewrite` + `lookup.cpp rewrite_allowed`）；③ 「平假名 + 片假名词」收尾时变形要么整段改写片假名词、要么不动（`min_rewrite`）；④ 结尾落在片假名词中间（下一个码点仍是片假名 / 长音符）时只认原文、不许还原（`process()` 的 `next_char`）。上游这条的主要动机是它自己的 full_collapse（删单个っ）造成的误匹配，fork 自 BUG-1777 起就不挂 full_collapse，那一半问题本来不存在；②在 fork 里只对中点与 `っっ` 折叠生效。改写处：走完都没碰到被删字符时 `max_rewrite` 返回「不限」而非走过的长度——fork 有比原文更长的变体（韩语拆字），照上游写法 ko.json 的长后缀规则会被误杀。`next_char` 只取扫描窗口内的码点（同 BUG-3212 的窗口口径：引擎结果只依赖前 `scan_length` 个码点，与 Dart 侧匹配长度缓存的键一致）。 |
| `e2a007f` | port 歴史的仮名遣い | **采纳 + 本地限制** | 60 条规则：ワ行五段的は / ひ / ふ / へ 各活用形、`-そう` 的 `さう`、volitional 的 `〜やう / 〜はう / ませう / からう`、`-いる` 的 `ゐる`，新组 `-ふ`。fork 给这 60 条全部打了 `"requiresPartOfSpeech": true`，经它们得到的还原形只对自带词性且匹配的词条成立，见下「本地差异」。 |
| `8e89a5d` | port -やしない and -やしません | **采纳** | 新组 `-やしない`（conditionsIn `adj-i`）/ `-やしません`（`-ません`），各 17 条。 |

**本地差异：歴史的仮名遣い规则要求词条自带词性（上游无此限制）。** 这批规则的词尾正是现代文最高频的
助词「へ / は」（`へ → う` imperative、`はず / はない / はぬ → う` 等，conditionsIn 为空）。带词性的
词典上，conditionsOut（多为五段动词）本来就会被词性过滤挡掉；但 fork 让无词性词典的词条当词性通配
（MDX / StarDict / DSL 写 `rules = "*"`，整本不带 rules 的 Yomitan 词典读侧把空 rules 当 `*`，
`Deinflector::pos_to_conditions`），任何还原在它们上都成立，于是 `うちへ` → 宇宙〔うちう〕、`レストランへ`
在「ラン」处 → 乱右〔らんう〕、`るはず` → るう，按最长匹配优先压过正确的短结果。通配让步对现代活用是
对的，对罕见正字法的短规则精度代价太大，所以按规则数据收窄：
- 表示：transforms JSON 的规则级字段 `"requiresPartOfSpeech": true`（ja.json 里恰好是 `e2a007f` 新增的
  60 条；并入既有组的规则与新组 `-ふ` 一样逐条标，不按组标——`negative` / `volitional` 等组里还有现代规则）。
- 读取：`deinflector.cpp` 载入时把带标记规则的 conditions_out 或上 `fushi::kRequiresPartOfSpeechBit`
  （`util/pos_required.hpp`，条件位的最高位，各语言的词性条件从 0 往上分、最多用到二十几位，载入时
  不再把第 63 位分给词性条件）；递归时这一位沿链传下去（`chain`），判 conditions_in 时先去掉（`admits`）。
  `lookup.cpp filter_by_pos` 见到这一位就只按词条**自带的真词性**匹配，通配 `*` 不算数（`explicit_rules`）。
  一条词条的 rules 是同一 (expression, reading) 在各词典里的词性并起来的（`query_raw` 逐本追加），
  常见词同时在带词性与无词性词典里时是 `"v5 *"`——有真词性且匹配就成立，不因为另一本给了通配而丢掉。
  链上任何一步用过带标记的规则即适用（`待ってゐる` → `待って` → 待つ 同样要求词性）。
- 代价：只在无词性词典里出现的词条不再吃歴史仮名还原（装载的词典里只要有一本给它标了词性就照常）；
  反过来，带词性的词典自己把历史假名词条标成 `v5` 的仍会命中（`散らふ`〔ちらう〕在「こちらへ」的
  「ち」处、`とう` 在「ことはない」的「と」处），词性过滤挡不住，与上游行为相同。

真实词典集（64 本）前后对比（加了本地限制之后）：`benchmark/corpus_ja.txt` 1143 次查词里 13 次结果有变
（首条变了 8 次）：11 次是片假名词边界去掉的跨词误配（`所でニャ` → 所で、`はバッテ` → は、`きたレ` →
きた 等），1 次只是顺序，1 次是 `スマートフォン` 的「ト」处多出带词性的 `トフ` → とう（非首条）；
不加限制时的歴史仮名误配 `ランへ` → 乱右、`るはず` → るう、`ワフ` → わう 全部消失。专用的歴史仮名 /
助词语料（640 次）上首条改变 89 次（不加限制 100 次），`言はない` / `歌はう` / `待ってゐる` / `言へば` /
`思はぬ` / `ませう` 等还原照常，`うちへ` / `どこかへ` / `いいへ` 等助词误配消失。

守卫：`tests/ja_upstream_sync_lookup_test.cpp`（真 ja.json：中点 / 串首串尾点保留 / 变形不跨点 /
片假名词边界 / 片假名收尾整段改写 / くって / 歴史的仮名遣い / -やしない / 歴史仮名规则在通配词典上不成立、标记沿链传递、真词性与通配并存时按真词性判）+ `tests/text_processor_test.cpp`
新增的中点与改写上下限用例 + Dart `fushi/test/dictionary/transform_description_i18n_test.dart`（新组说明的中文译文）。

## TODO-687 批3 移植的上游 commit（IPA 音标支持）

| 上游 commit | 标题 | 落到 Hibiki 的文件 | 移植方式 |
|---|---|---|---|
| `918744d` | basic support for ipa dicts (#12) | `query.hpp`（`PitchEntry::transcriptions`）+ `importer.cpp` + `yomitan_parser.{hpp,cpp}`（`parse_ipa` + `RawIPA`/`TranscriptionsArray` glaze）+ `query.cpp`（pitch/ipa 二分支）+ `popup_json.cpp`（自有，序列化 transcriptions + 并入 pkey）+ FFI/Dart 透传 | **非直抄**，见下 |

> 移植偏差（上游 diff 不能直接 patch）：
> - **`query.cpp` 按 Hibiki BlobReader 重实现**：上游用自由函数 `read_val/read_str(blob_addr)`，Hibiki 已重构为 `BlobReader.read<>()/read_str(len)`，故 pitch/ipa 二分支按 BlobReader 风格重写，逐字段对照上游（reading 过滤、`if(!pitch_positions.empty()||!transcriptions.empty())` 空集守卫）。
> - **`detect_type` 也加 `||ipa`**（上游 diff 没碰）：上游只改了 `process_meta_bank` 的 count 分支；但 Hibiki 多一层分类（C++ `detect_type` + Dart `decodeDictTypeFromBlobHeader`），纯 IPA 词典若不归入 "pitch" 就落 "term"、永不注册成 pitch 词典、数据查不出来。故 `importer.cpp detect_type` 与 `app_model.dart decodeDictTypeFromBlobHeader` 同步加 ipa→pitch。
> - **`popup_json.cpp` 去重 pkey 并入 transcriptions**（Hibiki 自有文件，上游无）：IPA 项 pitch_positions 为空，仅按 positions 建 key 会把同 dict 多 IPA 折叠成 `dict:` 被吞，故把 transcriptions 折进 key。Dart 侧 `buildPopupJsonFromLookup` / fallback `buildLookupEntryExtra`+`_convertPitches` 同步对齐。
> - **FFI ABI 变更**（native+Dart 同 commit）：`FfiPitch` 加 `char** transcriptions; int32_t transcription_count`，convert 照 `display_values`（malloc 数组 + 逐元素 dup），free **双层**（先逐元素再数组）。Dart binding `FfiPitch` 镜像 `FfiFrequency.displayValues`。
> - **UI 渲染未做**（用户决策 ③A）：本批只到 native+FFI+Dart 数据贯通 + parity，JS 弹窗渲染 IPA 作后续 TODO。
> - 守卫：`tests/ipa_import_query_test.cpp`（import→query→`PitchEntry.transcriptions` e2e，红绿实证）+ `dictionary_popup_webview_test.dart` parity 手加 transcriptions 断言。

## Hibiki 本地改动清单（上游没有 / 已分叉）

- **自研多语言文本处理器**（`fushidicts_src/text_processor/text_processor.cpp`）：P1 Unicode 小写（`to_lower`）/ P2 阿拉伯语 harakat + 组合记号删除（`harakat`/`combining`）/ P3 预合成拉丁去变音（`precompos`）。上游 `text_processor` 此前为空（仅日英归一化骨架）。
- **自研 kanji 导入**：`fushidicts_src/importer.cpp` 上游 541 行 → Hibiki **1367 行**（+826），新增 kanji bank 写盘（`write_kanji`）+ `query_kanji` + `add_kanji_dict`。
- **多格式导入**（上游主线没有）：`fushidicts_src/mdx/`（MDX）、`fushidicts_src/stardict/`（StarDict）、`fushidicts_src/popup_json.cpp`（弹窗 JSON）、`fushidicts_src/scan/`（词边界感知扫描，对齐 Yomitan searchResolution）、`fushidicts_src/util/`。
- **批量分词**（2026-10-19，上游没有）：`fushidicts_src/tokenize.cpp`（`fushidicts_include/fushidicts/tokenize.hpp`）——Dart `JapaneseLanguage.textToWords` 的逐位置最长匹配循环搬进原生，一次 FFI 切完整段（UTF-16 码元口径、句柄内匹配长度 LRU，`add_*_dict` / `load_transforms` 时清空）；`LookupOptions::materialize=false` 跳过截断后的 pitch 富化与释义解压（只给分词用）。新 FFI 导出 `fushidicts_tokenize` / `fushidicts_free_tokenize_result` / `fushidicts_match_length`。守卫 `tests/tokenize_batch_test.cpp`（旧 Dart 循环转写的参考实现逐段比对）。`fushidicts_tokenize` 收带长 UTF-8（`text, text_bytes`），正文里的 U+0000 不截断（HBK-AUDIT-007），守卫 `tests/tokenize_ffi_nul_test.cpp`（把 `fushidicts_ffi.cpp` 编进测试、经导出符号调用）。弹窗 JSON 拼装曾试过搬进原生，端到端比 Dart 慢（多一次 ~200 KB UTF-8 解码），已退回，仍由 Dart `buildPopupJsonFromLookup` 拼。
- **联合过滤器 / 分遍预取 / 查词基准**（2026-11-16，上游没有）：见上「2026-11 性能批」。`benchmark/`（`lookup_bench`，不进 ctest、不进产物）是量查词耗时与「改引擎前后结果逐字节相同」的装置，用法在 `benchmark/lookup_bench.cpp` 文件头。
- **按请求排除词典**（2026-11-09，上游没有）：`LookupOptions::excluded_dictionaries`（`fushidicts_include/fushidicts/lookup.hpp`）。`Lookup::lookup` 把排除集作为查找表传给 `DictionaryQuery::query_raw` / `enrich_freq` / `enrich_pitch`（`query.hpp` 私有接口加默认 `nullptr` 参数），名列其中的词典整本跳过：释义、跨词典合并的 rules / score、频率、音调都不进来，重定向也不跟随；Auto 频率词典序剔除它，显式指定的排序词典被排除 = 找不到。语义是「这次查词当作没装这本词典」，不占 `max_results` 名额、不影响排序。空集时传 `nullptr`，查库路径逐字不变。新 FFI 导出 `fushidicts_lookup_with_exclusions`（`fushidicts_lookup_with_ruby` 的参数 + `const char* const* excluded_names, int32_t excluded_count`），老导出不动；Dart `FushiDicts.lookup(excludedDictionaries:)`，后台查词把 `FushiLookupRequest.hiddenDictionaries` 同时交给引擎（原始结果缓存键带排除集后缀）。给服务端常驻全部词典、按客户端 profile 的启用集合逐请求切换用。守卫 `tests/excluded_dictionaries_lookup_test.cpp` + Dart `packages/fushi_dictionary/test/excluded_dictionaries_native_test.dart`。
- **index.json 语言字段写回**（2026-11-09，上游没有）：`Index`（`fushidicts_src/json/yomitan_parser.hpp`）追加 `std::optional<std::string> sourceLanguage / targetLanguage`，`import_yomitan` 把它们写回输出目录的 `index.json`（app 与 `fushi_server` 导入后从输出目录读来源 metadata，`parseSourceMetadataFromIndexJson` 读 `revision / indexUrl / downloadUrl / sourceLanguage / targetLanguage / isUpdatable`，语言被丢则词典管理无法按语言分组）。读侧经 `yomitan_parser.cpp` 内部 `RawIndex`（语言字段先收 `raw_json_view`），只在源值是非空字符串时落进 `Index`；空串 / null / 非字符串当缺席、导入不失败（此前这两个键是未知键直接忽略，宽容度不变）。写侧两个键排在原六键之后、nullopt 时省略，因此不带语言的源输出逐字节不变。Dart 读侧不读的键（author / url / description / attribution）不搬。守卫 `tests/index_language_roundtrip_test.cpp`。
- **安全上限**：导入/查询期的资源/尺寸上限加固。
- **FFI 桥**：`fushidicts_ffi.cpp`（Dart FFI，五端共用）。**不用上游 `c-bindings` 分支**。原 Android JNI 桥 `fushidicts_jni.cpp`（只服务已删除的原生弹窗 `PopupDictActivity`）已删除，Android `:popup` 进程走同一条 Dart FFI。
  - 注意：`score` / `get_freq_value(s)_for_dict` / `Dictionary` 均为引擎内部符号，FFI 桥与 Dart binding 均未暴露——本批三处改动**不影响 FFI 签名**。
- **只查词频的查询入口**（2026-11，上游没有）：`DictionaryQuery::query_frequencies` / FFI `fushidicts_query_frequencies` / Dart `FushiDicts.queryFrequencies`——与 `query()` 同一批词条、同样的 rules 与 frequencies，但不富化音调、不解压释义（glossaries / pitches 恒为空）。给 Anki 卡组按词频重排用（每张卡查一次、只读 reading 与 frequencies）。实测（64 本词典、677 个词，`lookup_bench --query-compare`）：`query()` 平均每个词解压 376 KB 释义，0.33 ms → 0.03 ms，两者词条 / 词频逐项相同。守卫 `tests/freq_pitch_merge_query_test.cpp`（每个查询点都比 `query()`）。
- **额外吸收的 sibling commit**：`feb48f5`（`ImportResult.detected_type`，自动词典类型检测），非 origin/main 主线。

## 依赖差异

- **上游**：`external/` 用 git submodule（utfcpp / glaze / zstd / unordered_dense / xxHash / libdeflate）。
- **Hibiki**：vendored 子目录 `native/fushidicts/fushidicts_external/`（glaze / libdeflate / unordered_dense / utfcpp / xxHash / zstd 实拷贝，不走 submodule）。批2 若引入 `utf8proc` 也照此 vendor 进 `fushidicts_external/`。

## 验证

- 本机 **MSVC 2022 可用**（批4 实证：`tests/run_all.bat` 走 vcvars64 + Ninja + ctest，全套 21 用例 ~6 秒）；「本机无 C++ 编译器」是过时说法。native 改动本地 ctest 先行，再由 **CI Linux ctest** + **5 平台 build** 兜异构。
- ctest 守卫：`tests/freq_pitch_import_query_test.cpp`（freq/pitch import→query e2e）+ `text_processor` / `kanji` 现有用例不回退。

## 2026-08 Hibiki→Fushi 改名映射（P6-2）

产品改名 Fushi 后，本引擎**对外符号面**同步改为 `fushidicts`。终局清算 W6（2026-08-07）又把**目录名**一并改掉：`native/hoshidicts/` → `native/fushidicts/`，内层 `hoshidicts_src/`→`fushidicts_src/`、`hoshidicts_include/`→`fushidicts_include/`、`hoshidicts_external/`→`fushidicts_external/`（vendored 第三方只改目录名，pristine 文件内容不动）。

W9-7（2026-08-08）补完 W6 只改了外层目录、没动内部命名的部分——内部符号与上游 diff 对照面无关，留着只会让「旧代号已清零」这句话不成立：
- 公共头 `fushidicts_include/hoshidicts.h`→`fushidicts.h`，公共头子目录 `fushidicts_include/hoshidicts/`→`fushidicts/`（源码 `#include "fushidicts/*.hpp"`）；
- 内部命名空间 `hoshi::`/`hoshi_test::`/`hoshidicts::`/`hoshidicts_json::` → `fushi` 系，线程封装类型 `HoshiThread`/`HoshiThreadFn`/`hoshi_thread_*` → `Fushi*`/`fushi_thread_*`；
- 宏 `HOSHI_EXPORT`→`FUSHI_EXPORT`、`HOSHI_LOG*`→`FUSHI_LOG*`；
- CMake 静态库 target `hoshidicts`→`fushidicts`，测试 harness 变量 `HOSHI_TEST_BUILD_DIR`→`FUSHI_TEST_BUILD_DIR`；
- CI workflow 文件名 `native-hoshidicts-gate.yml`→`native-fushidicts-gate.yml`。

**仍保持不变**：磁盘分片名 `.hoshidicts_1`（词典持久化契约，改名会让存量分片读不到）。对照表：

| 旧名 | 新名 | 说明 |
|---|---|---|
| C ABI 导出前缀 `hoshidicts_*`（22 个函数） | `fushidicts_*` | `fushidicts_ffi.cpp`，Dart 绑定同步 |
| CMake target/产物 `hoshidicts_ffi`（`hoshidicts_ffi.dll` / `libhoshidicts_ffi.{so,dylib}`） | `fushidicts_ffi`（`fushidicts_ffi.dll` / `libfushidicts_ffi.{so,dylib}`） | Windows/Linux/macOS/Android |
| iOS 合并归档 `libhoshidicts_ffi_merged.a` | `libfushidicts_ffi_merged.a` | `merge_ios_archives.sh` |
| CMake target `hoshidicts_jni`（`libhoshidicts_jni.so`） | `fushidicts_jni`（`libfushidicts_jni.so`） | Android popup JNI（后随原生弹窗一并删除） |
| JNI 注册 `Java_app_hibiki_reader_HoshiBridge_*` | `Java_app_fushi_reader_FushiBridge_*` | 后随原生弹窗一并删除 |
| 桥源文件 `hoshidicts_ffi.cpp` / `hoshidicts_jni.cpp` | `fushidicts_ffi.cpp` / `fushidicts_jni.cpp` | 仅这两个桥文件改名 |
| 构建变量 `HOSHIDICTS_*`（CMake/xcconfig/脚本环境契约） | `FUSHIDICTS_*` | `AppInfo.xcconfig` / 两个 pbxproj / `build_fushidicts_ffi.sh` |
| Dart 封装 `HoshiDicts` 及 `Hoshi*` 结果类 | `FushiDicts` / `Fushi*` | `packages/fushi_dictionary/lib/src/engine/fushidicts.dart` |
| 目录 `native/hoshidicts/`（含 `hoshidicts_{src,include,external}/`） | `native/fushidicts/`（`fushidicts_{src,include,external}/`） | W6；测试 harness 变量 `HOSHI_ROOT`→`FUSHI_ROOT`、ctest 函数 `add_hoshi_test`→`add_fushi_test`、CI 构建目录 `hoshi-tests`→`fushi-tests` 同批 |
