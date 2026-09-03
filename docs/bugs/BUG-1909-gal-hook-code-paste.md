## BUG-1909 · gal 特殊码只能靠手拼七列 TSV 导入：缺少粘贴入口与归一化
- **报告**：2026-08-28（用户：「gal，特殊码确实是可以用在 fushi 上的，不过要稍微转换一下，因为 fushi 只接受 tsv 合适的，一般特殊码只是一串字符。优化一下」）
- **真实性**：✅ 功能缺口（用户说的完全属实，且能精确定位）。

### 现状

texthooker 页的 Hook Code 工具栏只有三个 IconButton：保存 / 导入 / 导出。**没有任何
文本输入**。唯一能把自定义 H-code 送进 native 的用户路径是「导入一个 `.tsv` 文件」
（`FilePicker` 硬限 `allowedExtensions: ['tsv']`），而那份 TSV 的 schema 是：

```
exe_sha256	module_name	module_sha256	codepage	hook_code	label	options
```

`LunaHookCodeProfile.validate()` 硬校验：首列必须是 **64 位小写 hex 的 exe SHA-256**
（或 module 哈希），`codepage > 0`，`hook_code` 非空。

也就是说，用户拿到一串 `/HQN4@4CE90:game.exe`，要用上它必须：自己算 exe 的
SHA-256 → 补 codepage 932 → 补 label → 按 tab 拼行 → 存成 .tsv → 再走导入。
「需要转换一下」说的正是这一段。

（另注：那条导入路径实际调的是 `store.replaceFrom` —— **整表替换**，toast 却写「导入」，
用户已存的其它 profile 会被静默清掉。本次新入口刻意不走它。）

### 修复与测试

- **[x] ① 已实现**：
  - `galgame_hook_code_profile.dart` 新增纯函数 `normalizeGalHookCode(String)`：
    去首尾空白与包裹引号（英/中/日引号，可嵌套）、去掉**所有**内部空白（含换行——
    复制时的软折行）、**全角 ASCII → 半角**（中日文 IME 下粘出来的 `／Ｈ…` native
    一个字也认不出，而那纯粹是输入法噪声）。
    **红线：不碰码本身的结构** —— 不补/不删开头的 `/`、不改大小写、不重排 `@` 后的
    地址。Hibiki 从头到尾把 hook code 当**不透明字符串**搬运，真正的词法解析在
    LunaHost DLL 里（本仓 `third_party/lunahook/` 只有二进制）。在 Dart 侧替 native
    猜格式 = 开第二个真相源。
  - texthooker 页新增「粘贴特殊码」入口：收码 + 可选备注 → 归一化 → 用**当前运行游戏
    的 exe** 算 SHA-256 补上身份列（这正是用户手工拼 TSV 时最过不去的一关）→ 补
    codepage 932 → `store.upsert`。
    用 `upsert` 而不是导入那条路的 `replaceFrom`：粘一条码不该把用户既有的其它
    profile 全部清掉。
  - 没有运行中的游戏时直接拒绝并提示——算不出身份哈希，存下来也永远匹配不上。
  - 新增 6 条 i18n（17 语言）。此前全仓 grep「特殊码」**零命中**，工具栏是硬编码的
    英文 `'Hook Code · …'`。
- **[x] ② 已加自动化测试** — `fushi/test/mining/galgame_hook_code_paste_test.dart` 7 项：
  干净码原样保留（含不带斜杠的写法、大小写敏感）、引号/空白/换行/全角空格清洗、
  全角→半角、空输入归零、归一化后能通过 `validate()` 写成合法 TSV 行，
  以及接线守卫（粘贴入口必须 `upsert` 而非 `replaceFrom`、必须先归一化、必须补 exe 哈希）。
  **变异实测**（2026-08-28）：去掉全角→半角那一步 → 2 项转红。还原后
  mining + i18n 共 **1151 项**全绿。

### 备注

- **galgame 平台边界与支持状态**：本改动全在 Dart 侧（输入与 TSV 组装），
  **未触碰** `native/galgame_hook/`、未改 IPC 契约、未改
  `native/galgame_hook/engine-support.yaml`。因此**不构成任何引擎支持状态的变更**，
  也不声称任何引擎因此可用——它只是把「用户已经有的一条码」录进去这一步变得可行。
  真正是否 hook 得上，仍以原有的能力阶段与证据链为准。
- 未做真机复测（需要真实 galgame 运行中 + 一条已知可用的特殊码）。纯函数层已完整覆盖。
- **未修的相邻问题（另计）**：导入按钮走 `replaceFrom`（整表替换）却提示「导入」，
  会静默清掉用户既有 profile。这是独立的一条，改它要先想清楚「导入 = 合并还是替换」
  的产品语义。
