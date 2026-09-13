## BUG-2252 · CI 注入 OpenSubtitles key 生成双引号字面量，analyze 门必红
- **报告**：2026-09-07（合并 PR 时在 develop 上发现）
- **真实性**：✅ 真 bug。根因 `.github/actions/provide-baked-secrets/action.yml:73`（修复前）

  `Build Release APK` 的 `tests` job 在 develop 上连红两条提交（`b08e028b` 合入
  #1286、`fef9a09a` 合入 #1284），失败步骤都是 `Run dart analyze`，而它前一条
  `30b9070f` 是绿的。CI 报的是**一条 info**：

  ```
  info • Unnecessary use of double quotes. Try using single quotes unless the
         string contains single quotes
       • lib/src/media/video/subtitle/opensubtitles_default_key.dart:1:44
       • prefer_single_quotes
  1 issue found.  →  exit code 1
  ```

  #1286 引入的 OpenSubtitles 注入步骤照抄了 `google_oauth_secret.dart` 的写法：

  ```bash
  key_literal="$(python3 -c '... json.dumps(os.environ["OPENSUBTITLES_API_KEY"]) ...')"
  printf 'const String kBuiltinOpenSubtitlesApiKey = %s;\n' "$key_literal" > "$dst"
  ```

  `json.dumps` 产出的是**双引号** Dart 字面量，`>` 又把整个文件覆写掉（连入库的
  两行注释一起），于是 CI 上该文件第 1 行就是 `const String ... = "<key>";`——
  报错位置 `1:44` 正是那个双引号。

  能照抄成立的前提被漏掉了：`google_oauth_secret.dart` 与 `log_upload_secret.dart`
  **在 `fushi/analysis_options.yaml` 的 `analyzer.exclude` 里**，双引号不会被检查；
  `opensubtitles_default_key.dart` 不在。同类的 `tmdb_default_key.dart` 也不在
  exclude 里，所以它一直用 `sed` 只替换 const 那一行、保持单引号——那才是对的范式。

  **为什么本地测不出来**：本地 `flutter analyze` 看到的是入库的单引号空占位，
  永远绿；双引号只在 CI 注入 secret 之后才存在。加上 CI 的 analyze 门把 info
  也当失败（`dart analyze` 语义），这条 info 就成了硬红。

- **[x] ① 已修复** — `.github/actions/provide-baked-secrets/action.yml` 改为调用新增的
  `.github/actions/provide-baked-secrets/write_opensubtitles_key.py`：保留入库的两行
  注释、只重写 const 那一行，产出**单引号**字面量，并转义 `\`、`'` 与 `$`（单引号
  Dart 字符串里 `$` 仍是插值符，`abc$id` 形态的 key 不转义会编译失败）。
  转义放进独立 python 脚本而不是内联，是因为 YAML→bash→sed 三层里 `\$` 会被逐层
  吃掉——实测 `${VAR//'$'/'\$'}` 交给 sed 后反斜杠必然丢失，写不出正确结果。
  key 走环境变量而非 argv，不进进程列表。

  实测（三种输入 + 真 Dart 编译器回环）：未配 secret 时文件原样不动；正常 key 正确写入；
  含 `$ ' \` 的 key 写成 `'a\$id\'q\\b'`，`dart` 跑起来 `== r"""a$id'q\b"""` 为真
  （ROUNDTRIP_OK）。

- **[x] ② 已加自动化测试** — `fushi/test/tools/baked_secret_stub_quotes_guard_test.dart`：
  按 `dst=` 切出 action 里每个写 Dart 文件的步骤，凡目标不在 `analyzer.exclude`
  名单里的，断言该步骤不得产出双引号字面量；另断言 exclude 名单解析器自身有效
  （否则断言会变成恒真），以及生成脚本存在、模板是单引号、含 `$` 转义。
  **变异实测**：把原写法改回 `json.dumps` + `printf > "$dst"`，守卫立刻红并指名
  `opensubtitles_default_key.dart`；改回修复版后转绿。

- **备注**：这条只有 CI 能抓、本地恒绿，属于「合并后必跑目录枚举型守卫」也覆盖不到的
  盲区（它不在 `lib/`/`test/` 扫描面上，而在 `.github/`）。新增「烘进包的密钥」时，
  先确认目标文件在不在 `analyzer.exclude` 里，再决定能不能用 `json.dumps` 那套写法。
