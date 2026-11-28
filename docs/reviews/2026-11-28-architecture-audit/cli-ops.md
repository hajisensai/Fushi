# 架构审计：cli-ops

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

本域有三套同时存在的「操作面」。(1) app 的控制通道：fushi/lib/src/ops/ctl_*_routes.dart 手写约 477 条 CtlRoute，handler 自己用 call.optString/requireString 解析参数（约 635 处）。op_descriptions_*.dart 里另写约 430 条 OpDescription，靠 `METHOD pattern` 字符串挂回路由，拼成 OpCatalog，AI、`/api/admin/ops/call`、MCP（AiMcpToolHost）都从它派生；这一段是唯一真正单源的部分。packages/fushi_cli/lib/src/commands/*.dart 又手写约 489 条 CtlCommandSpec（flag、body 拼装、路径字面量、渲染），三份之间靠 op_catalog_ratchet_guard_test 和 ctl_cli_route_coverage_guard_test 对齐，后者是对 commands/ 目录做字符串字面量词法扫描。(2) fushi_server 的 admin API 是 admin_api.dart 里一个大 `switch ((method, path))`，用 startsWith/endsWith/substring 切路径，不用 CtlRoute。admin_ops.dart 为 server.* 目录把路径再写一遍，再造一个 shelf.Request 转发回这个 switch；只有 SRS 内容走 engine 的 srs_ctl_routes（app 与 server 共用，是现成的正确先例）。(3) `fushi_server ctl` 是第二个 CLI：平铺 ArgParser 加字符串 switch，有自己的 AdminClient、退出码映射和中英两遍的帮助文本，SRS 子命令与 fushi_cli srs 逐条重复。模块门、只读门这类横切判据散落在各 handler 里手写，描述里的 availability 又写一遍；HTTP/CLI 直连路由时完全绕过描述里的参数 schema 校验。撤销靠 kit 的「读路由 → 比较 → 写路由」，先比较后写入不是原子的，同类撤销覆盖 bug 已出现 4 次。

## op-triple-declaration

**一个操作要写三遍（路由 handler、OpDescription、CLI CtlCommandSpec），靠字符串键加词法扫描守卫对齐**

- 类型：缺单一登记源；规模 XL；价值 high；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/ops/ctl_url_import_routes.dart:74-104 路由手写 '$kUrlImportCtlRoot/probe' 与 POST，参数用 call.optString('referer'/'userAgent'/'lang') 现场解析
- fushi/lib/src/ops/op_descriptions_url_import.dart:24-100 同一组操作又写一遍 method/pattern 字面量与 OpParam（url/lang/subtitleUrl/referer/userAgent）
- packages/fushi_cli/lib/src/commands/url_import_commands.dart:37-80 第三遍：_root='/api/admin/url-import'，addOption('subtitle-url'/'referer'/'user-agent') 再手动映射成 body 的 subtitleUrl/referer/userAgent
- packages/fushi_cli/lib/src/ops/op_catalog.dart:42-60 OpCatalog.build 按 '${route.method} ${route.pattern}' 字符串把描述挂到路由，对不上只能运行时 StateError
- fushi/test/ops/ctl_cli_route_coverage_guard_test.dart:20-60,108-117 守卫靠扫 packages/fushi_cli/lib/src/commands 的字符串字面量（自带 _stringLiterals 词法器与插值折通配）证明 CLI 与路由双向对得上
- fushi/test/ops/op_catalog_ratchet_guard_test.dart:18 kUndescribedRouteBaseline=0：路由与描述的配对靠棘轮计数保证
- 计数（grep）：CtlCommandSpec( 489 处、OpDescription( 430 处、CtlRoute 构造 477 处
- packages/fushi_cli/lib/src/ops/op_routes.dart:1-4 注释自称『只要一条路由有描述，CLI 就自动能用』，但 commands/ 仍为每条操作手写专用子命令

机制：路由、描述、CLI 是三种互不引用的数据结构，唯一的连接键是手打的 `METHOD /api/admin/...` 字符串。参数名在三处各写一次：路由里 optString 的名字、OpParam 的名字、CLI 的 flag 名到 body 键的映射，还要做 kebab 到 camel 的手工转换。新增或改名一个参数要改三处，漏了只能靠两个守卫事后抓，其中 CLI 那个还是对源码文本做词法扫描。BUG-3648、BUG-5123 都是『某层漏接』这一类。

根本方案：新建单一声明 `OpSpec<A>`，放在 fushi_cli/ops 纯 Dart 里：id、method、pattern、带类型的参数表（OpParam 增加 cliFlag/positional 映射，默认从 camelCase 推出 kebab flag）、risk、availability、undo、可选 `cli: CliHints(group, verb, render)`，以及接收已校验 typed args 的 handler（不再拿裸 CtlCall 自己 optString）。每个域只写一份 `ops_<域>.dart`，导出 `List<OpSpec>`，合并并删除现在的 ctl_<域>_routes.dart 与 op_descriptions_<域>.dart 这一对。CtlRoute 和 FushiOp 都从 OpSpec 派生，不再手写。fushi_cli 的子命令由一个通用生成器从 OpSpec 现生成（group/verb 取自 id 的段或 CliHints，flag 与 positional 取自参数表），commands/*.dart 只留非平凡的 render 函数，按 op id 登记在 `Map<String, Renderer>`。删除：每个 commands/*.dart 里的 configure/build 两半、ctl_cli_route_coverage_guard_test.dart 整份、op_catalog_ratchet_guard_test 的未描述路由棘轮（类型上已不可能有无描述的路由）、OpCatalog.build 的字符串挂接。以后新增操作只在 `ops_<域>.dart` 写一个 OpSpec；需要好看的输出时再在 renderer 表加一行。守卫：编译期保证（CtlRoute 只能由 OpSpec 构造，构造函数设为库私有），外加一条『每个 OpSpec 都能生成合法的 CLI 命令、flag 不冲突』的单元测试。参数名是 wire 格式，迁移时必须逐条保持现有 wire 键不变。

要动：packages/fushi_cli/lib/src/ops/；packages/fushi_cli/lib/src/ctl_routes.dart；packages/fushi_cli/lib/src/ctl_commands.dart；packages/fushi_cli/lib/src/commands/；fushi/lib/src/ops/；packages/fushi_engine/lib/srs/srs_ctl_routes.dart；packages/fushi_engine/lib/srs/srs_ctl_ops.dart；fushi/test/ops/

核验说明：证据属实：OpCatalog.build 用 `${route.method} ${route.pattern}` 字符串把描述挂到路由上，对不上就抛 StateError（packages/fushi_cli/lib/src/ops/op_catalog.dart:42-60）；ctl_cli_route_coverage_guard_test.dart:20-30 自己承认是扫 commands/ 里的字符串字面量，method 不参与比对；kUndescribedRouteBaseline=0、kRoutesWithoutCliCommand 为空，说明三份声明现在必须一一对应。但有一处与设计意图冲突：docs/specs/2026-10-26-ai-operations-agent-design.md:82-84 明确写了 CLI 分两路，『手写命令……保留人类可读的好用参数』，再加通用的 `op ls|describe|call`，手写子命令是有意设计，不是补丁。op_routes.dart:1-4 那句『CLI 自动能用』说的是 `op call` 这条通用路径，审计员把它读成了承诺不再手写子命令。因此『路由 + 描述双写、靠字符串挂接』成立，属于值得收敛的结构问题；『CLI 子命令全部由生成器替代』只部分成立。

方案风险：1）CLI 的 flag、positional、别名、子命令名属于用户脚本面的契约（spec:74 写『CLI 线协议不变』）。从 camelCase 自动推 kebab 会改掉现有的特殊 flag（例如自定义 positional、短别名、`--srs-profile` 这种不和 wire 键同名的 flag），方案只说了保持 wire 键，没说保持 CLI 面。2）想把 CtlRoute 构造函数设为库私有，但 fushi_engine（srs_ctl_routes）和 server（admin_srs_ctl、admin_ops）都在库外构造 CtlRoute，必须一起迁到 OpSpec，否则编不过。3）不进 AI 目录的路由（kRoutePrefixesNotForAi 里的 /api/admin/ai/agent/）需要 exposeToAgent 标记，方案只在 server 那条里提到，这里没提。4）OpDescription 的 summary 按 spec:135 是给模型看的英文，CLI 帮助若由它生成，语言和措辞会变。

修正后的方案（以此为准）：保留目标：路由 handler 和描述合并成同一个 OpSpec 声明（同一对象里写 method/pattern/params/risk/availability/undo/handler），删掉 OpCatalog.build 的字符串挂接和未描述路由棘轮。CLI 一侧不要全量生成：以 OpSpec 句柄为键，手写命令只引用 `op.id` 或 OpSpec 常量（不再写路径字面量），由 OpSpec 提供路径填充和 body 键；对没有手写命令的 OpSpec，由生成器自动产生默认子命令。现有 CLI flag 和 positional 逐条冻结，加 golden 测试锁住 `--help` 输出与 argv→请求的映射。这样 ctl_cli_route_coverage_guard 就可以改成类型级引用检查（手写命令只能引用存在的 OpSpec），删掉词法扫描。

## spec-validation-bypassed-on-http

**参数 schema 只在 AI/ops.call 路径校验，CLI/HTTP 直连路由绕过它，handler 与 CLI 各自再手写一遍校验**

- 类型：缺单一登记源；规模 L；价值 high；用户可见
- 核验：部分成立

证据：

- packages/fushi_cli/lib/src/ctl_server.dart:141-152 匹配到路由后直接 `route.handler(...)`，不经任何描述 / schema
- packages/fushi_cli/lib/src/ops/op_catalog.dart:~186（OpInvoker）才做『未知参数 / 类型 / 枚举 / 必填』校验，只覆盖 AI 与 /api/admin/ops/call
- fushi/lib/src/ops/ctl_url_import_routes.dart:108-124 handler 里手写 http(s) 校验 _requireUrl/_optUrl
- packages/fushi_cli/lib/src/commands/url_import_commands.dart:39-48 CLI 里又写一遍同样的 http(s) 校验与错误文案
- packages/fushi_cli/lib/src/commands/srs_commands.dart:149-157 与 packages/fushi_server/lib/src/ctl/ctl_srs_commands.dart:44-50 各拷一份卡型枚举 word/sentence/word-and-sentence/click/audio，真相在 engine SrsCardType.wire（packages/fushi_engine/lib/srs/srs_ctl_routes.dart:562 校验时又现拼一次）

机制：描述里的 OpParam（required/enum/type）只是给模型看的元数据，不参与 HTTP 分发，于是每个 handler 都得自己 optString、判空、判枚举、拼错误信息，CLI 为了提前报错又抄一份。同一个约束有三份，文案不一致，枚举一改就漂移。

根本方案：与 op-triple-declaration 一起落地：CtlServer 分发时按 OpSpec 的参数表统一做解析和校验（类型、必填、枚举、`OpParamType.url` 这类语义类型自带的 http(s) 校验），再把 typed args 交给 handler。OpInvoker 与 CtlServer 共用同一个 `OpArgs.parse(spec, raw)`，错误码与文案只在这里产生。枚举参数的 enumValues 直接引用 engine 枚举（`SrsCardType.values.map((t) => t.wire)`），不再写字面量列表。CLI 不做语义校验，只做 argv 到 args 的形状转换，错误照服务端回包显示。删除：各 handler 的 _requireUrl 类私有校验、CLI 里的 CtlUsageError 语义校验、两处卡型字面量表。以后新增约束只改 OpParam 声明。

要动：packages/fushi_cli/lib/src/ctl_server.dart；packages/fushi_cli/lib/src/ops/op_catalog.dart；packages/fushi_cli/lib/src/ops/fushi_op.dart；fushi/lib/src/ops/；packages/fushi_cli/lib/src/commands/；packages/fushi_server/lib/src/ctl/ctl_srs_commands.dart

核验说明：ctl_server.dart:134-157 匹配到路由后直接调 route.handler，只检查了 requiresReady，没有做参数 schema 校验，这一点属实；OpInvoker 在 op_catalog.dart:120 起、:240 处有 enumValues 校验，只走 AI 和 ops/call 路径，也属实。卡型字面量在 CLI 里有两份（srs_commands.dart:155、ctl_srs_commands.dart:45，外加帮助文本 :90/:195/:219），属实。审计有一处说错：engine srs_ctl_routes.dart:562 用的是 `SrsCardType.values.map((t)=>t.wire)` 派生，本身就是单一来源，不是『又现拼一次』。

方案风险：HTTP 直连如果改成严格校验（拒绝未知参数），现有调用方会被打回，包括 WebUI、手机互联客户端，以及 CLI 顺手带上的额外键。这是对外行为变化，审计没标。另外 GET 请求的参数在 query 里、值都是字符串，统一解析时要按 OpParam 类型做转换，不能直接复用 body 的 JSON 类型判断。

修正后的方案（以此为准）：共用一个 `OpArgs.parse(spec, call)`，CtlServer 和 OpInvoker 都走它。HTTP 路径的未知参数先告警，不立即拒绝；等列出调用方并逐个核对后再收紧。query 参数按声明类型转换。CLI 保留 argv 形状层面的报错（缺 positional 之类），语义校验交给服务端。

## server-admin-hand-router-plus-forward-shim

**服务端 admin API 是手写 startsWith/substring 大 switch，server.* 操作目录再写一遍路径并伪造 shelf.Request 转发回去**

- 类型：app / 服务端各写一套；规模 L；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_server/lib/src/admin/admin_api.dart:154-175 按前缀把请求分给 backups/srs/srsCtl/dictionaries 子路由，其中 srs 与 srsCtl 都按 '$kAdminSrsPath/' 前缀各试一次
- packages/fushi_server/lib/src/admin/admin_api.dart:176-295 `switch ((method, path))` 配 `when path.startsWith(...) && path.endsWith('/cancel')`，再用 path.substring 手切 id（pairing/libraries/jobs/downloads/subscriptions 每类都切一遍）
- packages/fushi_server/lib/src/admin/admin_ops.dart:330-345 op() 用 description.pattern 新建 CtlRoute，handler 用 _forward(dispatch) 转回 AdminApi.handle
- packages/fushi_server/lib/src/admin/admin_ops.dart:180 _forward 构造假的 shelf.Request 走进程内 HTTP
- packages/fushi_server/lib/src/admin/admin_ops.dart:473-475,543-545,676-678 等 'server.library.add' → '/api/admin/libraries'，同一条路径在 admin_api.dart:212-221 已写过一次
- packages/fushi_server/lib/src/admin/admin_srs_ctl.dart:1-30 SRS 内容已用 engine 的 CtlRoute 表，说明正确结构在仓内已经存在，只是没推广

机制：服务端没有采用 app 与 engine 已有的路由抽象 CtlRoute，自己手写分发。为了让远端 AI 也有 server.* 工具，只好在描述层再造一份 CtlRoute 当壳，把请求序列化回 shelf 交给大 switch。结果每条 admin 端点的路径要在 switch、描述、`fushi_server ctl` 三处各写一次，路径解析也是逐 case 手切，新增端点只能复制前缀判断。

根本方案：把 AdminApi 改成 `List<OpSpec>` / CtlRoute 表，用 fushi_cli 的 CtlServer 分发逻辑（抽成可挂在 shelf 上的 `ctlShelfHandler(routes)`）；backups、dictionaries、srs 各自导出 route 列表后拼接。server.* 的描述与 handler 写在同一个 OpSpec 里；不进 AI 目录的端点（配对、凭据设置）用 OpSpec 上的 `exposeToAgent: false` 标记，不再靠『不写描述』表达。删除：admin_api.dart 的大 switch 与 _segment/substring 解析、admin_ops.dart 的 _forward / 伪 shelf.Request 层和 read()/irreversible() 路径复写。以后新增 admin 端点只写一个 OpSpec。wire 路径保持不变。

要动：packages/fushi_server/lib/src/admin/admin_api.dart；packages/fushi_server/lib/src/admin/admin_ops.dart；packages/fushi_server/lib/src/admin/admin_backups.dart；packages/fushi_server/lib/src/admin/admin_dictionaries.dart；packages/fushi_server/lib/src/admin/admin_srs.dart；packages/fushi_cli/lib/src/ctl_server.dart

核验说明：admin_ops.dart:330-345 的 op() 用 description.pattern 新建 CtlRoute，handler 走 _forward；admin_ops.dart:170-200 把请求重新拼成 shelf.Request，对没有 body 的请求还把 body 塞进 query 字符串，再派回大 switch。admin_api.dart:258-290 订阅一类就靠 startsWith/endsWith/_segment/substring 手切 id。admin_srs_ctl 用 engine 的 CtlRoute 表，这个先例属实。fushi_server 的 pubspec.yaml:40 已经依赖 fushi_cli，共用 CtlServer 没有依赖障碍。

方案风险：CtlRouteHandler 的签名是 `Future<Object?> Function(CtlCall)`（ctl_routes.dart:113），CtlServer 会先把 body 解析成 JSON（_jsonBody）。admin API 里有非 JSON 端点，比如 PUT /api/admin/upload 分块上传原始字节（admin_api.dart:375-376），以及 :463 的 `body: request.read()` 流式转发，现有的 CtlRoute 抽象表达不了。方案没留原始 shelf handler 的出口，直接套会破坏上传和流式端点。WebUI（web_ui.dart）也是这些端点的调用方，回包形状必须逐条保持。

修正后的方案（以此为准）：同意改成路由表加共用的 shelf 分发器，但要给 CtlRoute/OpSpec 加一个 raw 变体（handler 拿 shelf.Request、返回 shelf.Response），专门给 upload、流式代理和文件下载用，这一类不进 AI 目录。其余 JSON 端点全部迁成 OpSpec，删掉 _forward。迁移前先为现有 admin 端点录 golden 回包，供 WebUI 和 ctl 对照。

## capability-routes-three-hosts

**同一能力的路由在 app 控制通道、服务端 admin、互联 host 各写一套（订阅为实证），参数解析与回包形状互相分叉**

- 类型：app / 服务端各写一套；规模 L；价值 high；改持久化 / wire、用户可见
- 核验：成立

证据：

- fushi/lib/src/ops/ctl_download_subscription_routes.dart:43-118 app 的 /api/admin/subscriptions*，enable 缺 `enabled` 回 400、成功回整行
- packages/fushi_server/lib/src/admin/admin_api.dart:263-290 服务端同路径，`body['enabled'] == true`（缺失按 false 静默停用）、回 {ok:true}
- packages/fushi_engine/lib/sync/subscriptions/host_subscription_routes.dart:80-100 互联 /api/subscriptions 第三份，自己 jsonDecode，`enabled is! bool` 时回纯文本 400
- docs/bugs/BUG-3648-subscription-ops-split-ui-ctl.md 已记录同一组订阅操作两份实现导致语义分叉、撞 CHECK 约束，修法是再加一份 app 路由『与服务端 admin API 同形』，没有合并成一份
- packages/fushi_engine/lib/srs/srs_ctl_routes.dart 加 packages/fushi_server/lib/src/admin/admin_srs_ctl.dart:31-60：SRS 已做成 engine 路由加宿主（SrsCtlHost）注入，app 与 server 共用，是可复制的先例

机制：能力的业务门面（PipelineSubscriptionHost）已经在 engine 共用，但 HTTP 外壳由每个宿主各写一份。三份外壳各自解析 body、决定回包形状和错误语义，同一个 CLI 动作在不同目标上行为不同（缺参静默停用 vs 400）。BUG-3648 的修法是再加第三份『同形』外壳，没有收敛。下载、库管理在 admin_api 与 app ctl 中也有同名路径（admin_api.dart:212-260），是否同样分叉未逐条核对（推测）。

根本方案：按 SRS 先例推广：engine 里为每个跨宿主能力提供 `build<Cap>Ops(<Cap>OpHost host) → List<OpSpec>`（纯 Dart，无 Flutter），宿主只注入门面、模块门和写后通知。app 的 ctl、server 的 admin、互联 host 都挂同一份 OpSpec 列表。互联 host 的不同前缀 /api/subscriptions 用挂载前缀参数解决，不复制 handler。第一批：subscriptions、downloads、libraries/jobs。删除：ctl_download_subscription_routes.dart 的 handler 体、admin_api.dart 对应 case、host_subscription_routes.dart 的手写解析。守卫：engine 侧一条契约测试，用三种宿主假实现跑同一组用例，保证回包与错误一致。注意：统一后服务端 enable 缺参会从静默停用变成 400，属于对外行为变化。

要动：packages/fushi_engine/lib/sync/subscriptions/；packages/fushi_engine/lib/downloads/；fushi/lib/src/ops/ctl_download_subscription_routes.dart；packages/fushi_server/lib/src/admin/admin_api.dart；packages/fushi_server/lib/src/admin/admin_ops.dart

核验说明：三份实现逐条核对属实。app 侧 ctl_download_subscription_routes.dart 的 enable 缺 enabled 时回 badRequest，成功回整行。server 侧 admin_api.dart:272-278 用 `body['enabled'] == true`，缺参等于静默停用，成功回 {ok:true}。互联侧 host_subscription_routes.dart:88-94 在 `enabled is! bool` 时回纯文本 400，另外还多一道 `..`/`/` 的 id 检查（:79），而 server 那份用的是 Uri.decodeComponent 且不做这道检查。所以三份分叉不止回包形状，连安全校验也不一致。changesPersistenceOrWire=true 标得对。

方案风险：互联 host 的回包（HostSubscriptionRejected 回 reason/message JSON、纯文本 400）由手机端客户端消费，统一后会影响老版本客户端，需要核对互联协议的版本兼容策略。app 回整行、server 回 {ok:true}，统一时必须选一种并同步改 CLI 的渲染。下载、库管理两块是否也分叉，审计标了推测，未核实。

修正后的方案（以此为准）：按 SRS 先例落地：engine 里写 `buildSubscriptionOps(host)`，三个宿主共用。回包取并集形状（返回整行，同时带 ok:true），对旧客户端只增不减。错误统一成 JSON 的 {code,message}。互联前缀用挂载参数实现。id 校验（拒绝 `..` 和 `/`）放进共享层，三端统一执行。

## two-cli-frameworks

**fushi_cli 与 fushi_server ctl 是两套 CLI 框架：命令重复（SRS 整组）、HTTP 客户端两份、退出码映射两份、帮助文本手写三遍**

- 类型：缺单一登记源；规模 L；价值 high；用户可见
- 核验：成立

证据：

- packages/fushi_server/lib/src/ctl/ctl_srs_commands.dart:20-486 与 packages/fushi_cli/lib/src/commands/srs_commands.dart:149-585 打同一组 /api/admin/srs/{decks,notes,stats,conflicts,duplicates,retained} 端点，各自实现 flag 解析与渲染（文件头 1-5 行自认『背后是同一份 engine 路由，所以动作名与参数也照它的来』）
- packages/fushi_server/lib/src/ctl/ctl_commands.dart:799-890 动词用 `case 'pairing': switch(...) case '' || 'ls'` 字符串分发，205 行别名表手写；fushi_cli 则用 CtlCommandGroup 注册表（packages/fushi_cli/lib/src/ctl_command_registry.dart:22-42）
- packages/fushi_server/lib/src/ctl/ctl_commands.dart:225-240 与 :284 起中英两份用法文本，加上文件头 :8-29 的 docstring，同一用法写了三遍
- 退出码：packages/fushi_cli/lib/src/ctl_cli.dart:30 注释称『沿用 fushi_server ctl 的 sysexits 约定，两个 CLI 同一套判断』，但 ctl_cli.dart:290-298 按错误码（unauthorized/not_ready/'conflict'/unreachable）映射，ctl_commands.dart:574-580 按 HTTP status（401/409/0）映射，是两张独立的表
- HTTP 客户端两份：packages/fushi_cli/lib/src/ctl_client.dart（139 行）与 packages/fushi_server/lib/src/ctl/admin_client.dart（407 行）

机制：server 的 ctl 起步早于 fushi_cli 的命令注册表，后来没有迁移，只把 renderCtlTable 借过去用。每当 engine 路由被两边共用（SRS），CLI 层就要在两个框架里各写一遍。退出码、--json、错误输出各自实现，脚本在两个 CLI 上得到的判断不一致，与注释承诺相反。

根本方案：CLI 只保留一个框架，即 fushi_cli 的命令生成器（见 op-triple-declaration），在下面抽出 `CtlTransport` 接口，三个实现：app 控制通道端点、server admin（url/token/fingerprint）、互联 host（--interconnect）。`fushi_server ctl` 变成同一个生成器加 ServerAdminTransport，命令表来自 server 的 OpSpec 目录（经 /api/admin/ops 拉取或编译期共享）。离线子命令（scan/status/pair 等开库命令）不动。退出码与 --json 输出放进单一 `CliOutcome` 映射，统一用结构化错误码，不用 HTTP status。帮助文本由 OpSpec 的 summary 与参数描述生成，中英文按现有 server_language 的 tr 机制（若保留双语，描述字段改为双语对象）。删除：ctl_srs_commands.dart、ctl_commands.dart 的动词 switch 与手写用法块、admin_client.dart 中与 ctl_client 重复的部分、两张退出码表合成一张。以后 server 新增可 ctl 的端点不用写任何 CLI 代码。

要动：packages/fushi_server/lib/src/ctl/；packages/fushi_server/lib/src/cli.dart；packages/fushi_cli/lib/src/ctl_cli.dart；packages/fushi_cli/lib/src/ctl_client.dart；packages/fushi_cli/lib/src/ctl_commands.dart

核验说明：两张退出码表属实：ctl_cli.dart:290-298 按错误码映射（'conflict'→TempFail），ctl_commands.dart:574-580 按 HTTP status 映射（409→75），和 ctl_cli.dart:30 注释里『同一套判断』的说法矛盾。ctl_commands.dart 里有 63 个 `case '` 字符串分发；SRS 子命令在两边各实现一遍，卡型枚举和帮助文本也重复了（ctl_srs_commands.dart:45/195/219）。

方案风险：`fushi_server ctl` 的帮助是中英双语（ctl_srs_commands.dart:195 与 :219 是两套），fushi_cli 只有中文，OpDescription 又是英文。如果改由 OpSpec 生成帮助，必须给描述加双语字段，否则服务端用户看到的语言会变。命令表若改成经 /api/admin/ops 运行时拉取，服务器离线时 ctl 就不能列出命令或打印帮助，所以应在编译期共享。退出码统一后，现有服务端脚本对 409/401 的判断要保持不变。

修正后的方案（以此为准）：同意合成一个 CLI 框架，加 CtlTransport 抽象。命令表在编译期共享，不运行时拉取。退出码统一按结构化错误码映射，并保证现有的 64/69/75/77 取值不变。帮助文本用双语描述字段或 i18n key 生成，不能直接用给 AI 看的英文 summary。

## cross-cutting-gates-in-handlers

**模块门、只读门在 handler 里逐个手写，描述里的 availability 再写一遍，两者可能不一致**

- 类型：守卫代替结构；规模 M；价值 high；不改外部行为
- 核验：部分成立

证据：

- 『数据已迁移到新版，旧版处于只读状态』字面量在 fushi/lib/src/ops 下 17 个文件里出现 23 次，如 ctl_book_metadata_routes.dart:156,277,314,327、ctl_url_import_routes.dart:88，外加多份私有 _requireWritable/requireWritable（ctl_audiobook_routes.dart:123、ctl_collection_routes.dart:53）
- 模块关闭的拒绝文案在 route 侧各写一份：ctl_url_import_routes.dart:67-71、ctl_music_routes.dart:223、ctl_music_import_routes.dart:253、ctl_manga_ocr_routes.dart:103、ctl_tts_support.dart:217、ctl_audiobook_routes.dart:143
- 同一门在描述层又声明一次：op_descriptions_url_import.dart:24 `kit.whenModule(ModuleId.video)`；op_describe_kit.dart:197-200 whenModule；op_descriptions_srs.dart:18 与 op_descriptions_srs_mined_import.dart:26 还各自内联了一份 module_disabled 判断

机制：availability 只决定 AI 能不能看到这个工具，HTTP 分发不看它，所以 handler 必须自己再拦一次。只读门完全没有声明位置，只能靠每个写 handler 记得调用。写操作漏调只读门、或描述与 handler 的模块不一致时，没有任何东西能发现。

根本方案：OpSpec 上的 availability（模块门、合规门组合）与 risk 由分发层统一执行：CtlServer/OpInvoker 在调 handler 前先求 availability，不可用时按 code 回 409/403，文案由 code 统一生成；risk 为 write/irreversible 的操作在宿主只读时由分发层统一拒绝，宿主通过 OpHost.isReadonly 注入。handler 里不再出现模块门或只读门。删除：23 处只读文案、各 _requireWritable、route 侧的模块拒绝与对应局部 helper。以后新增写操作自动受只读门保护；需要按参数动态决定门（如 library 按 kind 选模块）时，availability 接收 typed args，仍然只声明一次。

要动：packages/fushi_cli/lib/src/ctl_server.dart；packages/fushi_cli/lib/src/ops/op_catalog.dart；fushi/lib/src/ops/op_describe_kit.dart；fushi/lib/src/ops/

核验说明：『数据已迁移到新版』这句文案在 fushi/lib/src/ops 的 17 个文件里出现 23 次，属实。各路由里的模块拒绝和描述里的 whenModule 是两份，也属实。但只读门不只在 ops 里用：fushi/lib/src/media/collections/collection_art_scrape.dart:45,108 的 UI/后台刮削路径也用同一道门（注释写着『与 ops 路由同一道门』）。把只读门放到分发层，只能保护控制通道，UI 和后台写路径仍然得自己手写。另外，ctl_server.dart 已经有 route.requiresReady 这个结构化门，横切门放在分发层有现成先例。

方案风险：OpRisk（write/irreversible）的语义是给 AI 用的确认等级，不等于『会写旧版数据库』。按 risk 统一拒绝，会误伤只写偏好、开窗口、做导出这类在只读状态下本该允许的操作，也会漏掉标成 read 却有副作用的操作。

修正后的方案（以此为准）：模块门（availability）由分发层统一执行，这部分成立。只读门往下沉到存储写入层（仓储或数据库写入口在只读时统一抛出带 code 的异常，由分发层映射成 409），UI、后台、ops 三条路径共用同一个判据。OpSpec 不再用 risk 推断是否只读，handler 和路由里的只读调用全部删掉。

## undo-read-compare-write-toctou

**撤销采用『读路由、比较、写路由』的非原子模式，且整行快照回写，同一机制已出 4 个撤销覆盖类 bug、逐个修**

- 类型：成类 bug；规模 L；价值 medium；用户可见
- 核验：部分成立

证据：

- fushi/lib/src/ops/op_describe_kit.dart:58-107 snapshotUndo.revert：先 `await read(params)` 用 sameJson 比较，再 `await write(params, old)`，两次独立的路由调用之间没有任何互斥
- fushi/lib/src/ops/op_describe_kit.dart:120-150 readBackUndo 把读写都落到 callRoute 字符串路由上，比较与写入跨两个事务
- docs/bugs/BUG-5143-video-section-undo-overwrites-concurrent-edit.md：事务外读、事务内写，盖掉并发新值，靠在 fushi_core 新增专用 compareAndSetVideoCollectionSectionOverride 单点修复
- docs/bugs/BUG-4481-srs-edit-undo-blind-overwrite.md：SRS 撤销闭包按内存旧值盲写
- docs/bugs/BUG-5220-manga-audio-undo-clobbers-line-edits.md：整行快照放回，抹掉之后独立的编辑，修法是为漫画有声单独写 mangaRenderedAudioRestored
- docs/bugs/BUG-5191-manga-audio-ctl-write-races-render-job.md：控制通道写与整卷生成无互斥，① 仍未修

机制：OpUndo 的契约只要求 capture/record/revert 三个闭包，kit 给出的默认实现是在路由层先读后写。存储层没有条件写原语，撤销也没有『本操作拥有哪些字段』的概念，于是每个域发现竞态后各自补一个 CAS 或字段级还原函数，同一机制反复出现。

根本方案：撤销契约改成字段级条件写：OpUndo 的 revert 只能通过宿主提供的 `UndoStore.restoreIfCurrent(entity, ownedFields, expected, previous)` 完成。比较与写入在同一条 SQL 或同一把写锁里，由 fushi_core/engine 的仓储层实现，超出范围的回 superseded。OpSpec 声明 undo 时必须列出 ownedFields，kit 只保留基于该原语的 snapshotUndo，删除 readBackUndo 的『读路由 → 写路由』路径和各域的专用还原 helper（mangaRenderedAudioRestored 之类改为 ownedFields 声明）。长任务互斥（BUG-5191）用实体级写锁 `EntityWriteGate.run(key, fn)`，由分发层按 OpSpec 声明的 `lockKey(args)` 自动加锁，写操作与后台任务共用这把锁。守卫：kit 层用 QueryInterceptor 注入并发写的通用契约测试，对所有带 undo 的 OpSpec 跑一遍。

要动：fushi/lib/src/ops/op_describe_kit.dart；packages/fushi_cli/lib/src/ops/op_undo_kit.dart；packages/fushi_cli/lib/src/ops/fushi_op.dart；packages/fushi_core/lib/src/database/；packages/fushi_engine/lib/srs/；fushi/lib/src/ops/ctl_tts_support.dart；fushi/lib/src/ops/ctl_tts_batch.dart；fushi/lib/src/ops/ctl_video_organize_routes.dart

核验说明：op_describe_kit.dart:58-107 的 snapshotUndo.revert 先 `await read` 比较，再 `await write`，中间没有互斥，非原子属实。BUG-5191 的 ① 仍未修，属实（BUG-5191 文件第 4 行）。不过 4 个 bug 不全是同一种机制：BUG-4481 是 SRS 撤销闭包按内存里的旧值盲写，根本没比较，和『读-比-写竞态』是两类问题；BUG-5220 是整行快照的粒度太粗。说它们都缺『字段级条件写』原语成立，说它们都是 TOCTOU 不准确。

方案风险：撤销目标分散在好几种存储里：drift 数据库、偏好、文件，还有 Rust 胖核心持有状态的子系统（按架构硬规则，SRS 这类状态归 native 所有）。一个落在 fushi_core 仓储层、基于 SQL 的 `UndoStore.restoreIfCurrent` 覆盖不了偏好、文件和 Rust 侧状态，每种后端得各自实现 CAS。另外，靠分发层按 lockKey 自动加锁只管得住控制通道；BUG-5191 里复核页保存和 runMangaRenderJob 都不经过分发层，必须由领域服务自己持有这把锁。

修正后的方案（以此为准）：把 OpUndo 的 revert 契约改成依赖一个按后端注入的 `ConditionalRestore` 接口（数据库用同事务的 CAS，偏好用带版本号的写入，Rust 子系统由 native 提供条件写命令），并要求声明 ownedFields。实体写锁放在领域服务层（例如 MangaAudio 服务），UI、后台任务、ops 共用；分发层只负责调用，不负责持有这把锁。

## stringly-route-refs-and-name-regex-guard

**撤销与组合操作用字符串调路由（185 处 kit.callRoute），地址类参数的确认要求靠参数名正则加 15 条豁免表猜**

- 类型：守卫代替结构；规模 M；价值 medium；不改外部行为
- 核验：成立

证据：

- fushi/lib/src/ops/op_describe_kit.dart:22-42 callRoute 按 method+pattern 字符串查路由，查不到或缺路径参数时才运行时 StateError
- fushi/lib/src/ops/op_descriptions_url_import.dart:85-95 撤销写死 `kit.callRoute('DELETE', '/api/admin/library/items/:key', ...)`；全目录 kit.callRoute( 共 185 处
- fushi/test/ops/op_catalog_ratchet_guard_test.dart:28-63 kAddressParamOpsWithoutConfirmation 15 条豁免，加 _addressParamName 正则 `(url|uri|link|endpoint|magnet|href|host|address)s?$`，从参数名猜『会不会向该地址发请求』，links.* 的 endpoint 只是本地条目引用也得逐条豁免
- fushi/test/ops/op_catalog_ratchet_guard_test.dart:66-69 装扩展必须确认，也靠 id 正则 `^online\.(extension\.(install|update)\w*|repo\.add)$` 匹配

机制：参数只有 string/integer 这类形状类型，没有语义类型，『向外部地址发请求』这种安全属性无处声明，只能由守卫按命名惯例推断，再用豁免表修正误判。操作之间的引用也没有类型化句柄，改路由路径后，撤销链要到真正执行撤销时才会断。

根本方案：OpParam 增加语义类型：`OpParam.remoteUrl`（会被请求的外部地址，声明即强制 needsConfirmation）、`OpParam.entityRef`（本地条目引用），以及用于装扩展的 `OpRisk.installsCode` 或 `OpSpec.executesUntrustedCode` 标记，由 OpSpec 构造器在 const 断言或 catalog 构建时强制确认，不再按名字猜。组合与撤销引用其他操作时用 OpSpec 常量句柄（`libraryItemRemove.call(kit, args)`），路径参数由 typed args 填入，不再写 pattern 字符串。删除：kAddressParamOpsWithoutConfirmation、_addressParamName、_extensionInstallOp 及对应用例，callRoute 的字符串重载。以后新增带地址的操作只需选对参数类型。

要动：packages/fushi_cli/lib/src/ops/fushi_op.dart；fushi/lib/src/ops/op_describe_kit.dart；fushi/lib/src/ops/op_descriptions_*.dart；fushi/test/ops/op_catalog_ratchet_guard_test.dart

核验说明：op_describe_kit.dart:22-42 的 callRoute 按字符串查路由，失败时运行期抛错。op_catalog_ratchet_guard_test.dart:28-69 用参数名正则加豁免表，扩展安装也按 id 正则判定。两者都是用守卫推断本该由类型声明的语义，属实。

方案风险：新增语义类型 remoteUrl/entityRef 时，现有 OpParam 的 wire 类型（给 AI 的 JSON schema 是 string）必须保持不变，语义类型只能作为附加元数据；否则会改变 MCP 和 AI 工具 schema，影响外部 MCP 客户端。改成 OpSpec 句柄这一步依赖 op-triple-declaration 先落地。

## 核验补充（审计漏掉的）

- 只读门不只在 ops 里用：fushi/lib/src/media/collections/collection_art_scrape.dart:45,108 也在 UI/后台路径上手写同一道门。真正该统一的地方是存储写入层，不是 CtlServer 分发层；审计的方案只收拢了控制通道这一半。
- 非 JSON 端点没有抽象可用：CtlRouteHandler 只能返回 JSON 对象（packages/fushi_cli/lib/src/ctl_routes.dart:113），CtlServer 会先把 body 解析成 JSON。server 的 upload 分块 PUT（packages/fushi_server/lib/src/admin/admin_api.dart:375-376）和流式代理（:463）因此只能留在手写 switch 里。这是 admin API 没能整体迁到路由表的结构性原因，审计没指出。
- 安全校验在各宿主间分叉：互联 host 的订阅 id 会拒绝 `..` 和 `/`（packages/fushi_engine/lib/sync/subscriptions/host_subscription_routes.dart:79），server admin 那份只做 Uri.decodeComponent，不做这道检查（admin_api.dart:284-289）。三宿主不收敛，问题就不止语义不一致，还有输入校验漏洞。
- admin_ops.dart 的 _forward 对没有 body 的请求，把 body 键值用 `'${e.value}'` 字符串化后塞进 query（packages/fushi_server/lib/src/admin/admin_ops.dart:170-178）。经 server.* 目录调用的 GET 操作会把列表、对象参数压扁成字符串，和直连 HTTP 的类型语义不一致。
