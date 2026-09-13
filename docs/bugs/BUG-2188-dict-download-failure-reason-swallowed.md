## BUG-2188 · 词典下载失败原因被吞：单行标题截断 + 摘要措辞错成导入失败 + 无镜像回退
- **报告**：2026-09-06（用户：Android 词典管理页截图两张——① 进度框标题 `下载失败：Wiktionary JA-ZH (中文): DioError [connection ...`，原因在这里被截断；② 随后一条红色 toast `导入失败: Wiktionary JA-ZH (中文)`，一个字的原因都没有。用户原话：「下载失败，没有说明具体错误原因。并且我们应该用 cf、git 等帮忙传一下」）
- **真实性**：✅ 真 bug。**四个各自独立的根因**，前三个决定「为什么看不到原因」，第四个决定「为什么会失败」：
  1. **长错误被塞进单行标题**（用户看到 `DioError [connection ...` 的直接原因）——
     `dictionary_dialog_page.dart` 的收尾把整串异常写进 `progressNotifier.value`，
     而进度框把它当**标题**渲染：`DictionaryDownloadProgressDialog` →
     `FushiModalSheetFrame(title: message)` → `fushi_material_components.dart:1047-1053`
     的 `Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis)`。
     **一个 `ValueNotifier<String>` 同时承担「阶段标题」和「诊断全文」两种职责**，
     而这两者的排版约束正好相反。收起后的状态行同样只给 2 行。
  2. **异常在收集那一刻就被降维成一个名字**（根因中的根因）——
     `final List<String> failedNames`，catch 里 `failedNames.add(rec.name)`。
     原因从此不在数据里，**后面无论怎么改渲染都救不回来**。
     `DictionaryImportManager.formatImportFailureSummary(List<String>)` 的签名把这个
     缺陷固化成了跨三条路径（在线下载 / 文件批量 / 目录批量）的共享契约。
  3. **下载阶段失败被报成「导入失败」**——同一批 `failedNames` 交给
     `formatImportFailureSummary`，措辞恒为 `t.srt_import_error`（"导入失败"）。
     于是一次下载失败被呈现两遍、且第二遍说的是另一个阶段，用户合理地以为
     「先下载失败，然后又导入失败」。**实际上下载失败后根本不会走导入**：
     `download` 抛出后直接进 catch，`importDictionary` 一次都没被调用，
     半个 zip 由 `finally` 整棵删。
  4. **该词典托管在 huggingface.co，且词典链路没有任何镜像回退**——
     `dictionary_downloader.dart` 的 `_wtyBase =
     'https://huggingface.co/datasets/daxida/wty-release/resolve/main/latest/dict'`。
     Android 上 `app_proxy.dart` 的 GUI 系统代理探测**只覆盖桌面三平台**，
     手机上只剩 env + 用户手填，于是直连 huggingface.co 吃满 30 秒
     `connectTimeout`。仓库里已有一套 GitHub 公共镜像层
     （`utils/net/github_mirrors.dart`，更新检查 / Mihon / 着色器三条链路在用），
     但 `fushi_dictionary` 是它的下游包，反向 import 不了，一直没接。
- **镜像可行性实测（2026-09-06，经本机代理逐条量过，用于否掉「随便挂个公共镜像」）**：

  | 候选 | 对 `.../wty-ja-zh.zip` 的实测结果 |
  |---|---|
  | `huggingface.co` 直连 | 302 → `us.aws.cdn.hf.co` → 200，`content-length: 6840013` |
  | `hf-mirror.com` | **308 跳回 huggingface.co**，不代理 `/datasets/.../resolve/` |
  | `ghfast.top` | **403 FORBIDDEN** |
  | `gh-proxy.com` | **403 Forbidden** |

  即：**没有任何现成公共镜像能救 wty（Wiktionary）系列**。能靠镜像救的是 catalog 里
  GitHub 托管的条目（jitendex / MarvNC / Kuuuube）。用户提的「用 cf 帮忙传」需要在
  fushi.moe 侧自建 Worker 反代或把包镜像进 R2，属于**站点仓库的基建改动**，本条不做，
  见下方「未做」。
- **[x] ① 已修复** — 四层对应四个根因，分支 `worktree-fix-dict-download-error-anki-parallel`：
  - **数据结构先改**（根因 2/3）：新增 `DictionaryTaskFailure{name, stage, error, url}`
    与 `DictionaryTaskStage{download, import}`（`dictionary_import_manager.dart`）。
    三条路径的 `List<String> failedNames` 全部换成 `List<DictionaryTaskFailure>`，
    catch 里带上异常本体与阶段（下载点用 `zipDownloaded` 标志区分两个阶段）。
    `formatImportFailureSummary` 改吃新类型，措辞按 `stage` 选，多条汇总改成
    **一行一条、每行带自己的原因**（旧实现是名字逗号连成一行、原因一个不给）。
  - **归因与人话**（根因 1 的另一半）：包内新增
    `DictionaryDownloadFailureKind`（connectTimeout / stallTimeout / connectionError /
    badResponse / cancelled / other）+ `classifyDictionaryDownloadFailure` +
    `DictionaryDownloadException{url, attemptedUrls, cause, kind, host, statusCode}`。
    app 侧 `describeDictionaryFailure` 把它翻成「连接 huggingface.co 超时，当前网络
    可能访问不了这个站点」这类点名到主机的一行中文（新增 7 个 i18n key × 17 语言）。
  - **渲染分道**（根因 1）：controller 新增 `detail` notifier（多行正文），
    `message` 恢复成「短标题」的单一职责；`DictionaryDownloadProgressDialog` 新增
    `detailListenable`，在进度条下方以 `SelectableText(maxLines: 6)` 渲染。
    结束提示改走 `DictionaryDownloadOutcome.details` + `AppModel._presentDictionaryOutcome`
    → 复用 `showErrorDetails`（可滚动 / 可选中 / 一键复制），不再只发一条被
    Android 12+ 强制截成两行且不可复制的原生 toast。拿不到全局 context 时退回 toast，
    提示不会因此静默丢失。
  - **候选回退**（根因 4）：包内新增进程级钩子 `dictionaryUrlCandidatesResolver` +
    `dictionaryDownloadCandidates`（与既有 `dictionaryDioFactory` 同一套装配方向），
    `DictionaryDownloader.download` 改为逐候选尝试；**只有传输层失败才换下一个**
    （已答复的 404/403 换镜像拿到的是同一份 404），换之前删掉半个文件、进度条归零。
    app 侧 `installDictionaryUrlCandidatesResolver` 接到 `gitHubMirrorCandidates`。
    **取消必须原样抛出、绝不包进 `DictionaryDownloadException`**——全仓
    `DictionaryDownloadController.isCancellation` 按 `DioError.type == cancel` 判
    「取消不是失败」，包起来就会把用户点取消记成一条下载失败。
- **[x] ② 已加自动化测试** — 新增 `fushi/test/dictionary/dictionary_download_mirror_fallback_test.dart`
  （15 条）+ 重写 `fushi/test/models/dictionary_import_failure_summary_test.dart`
  （新增 5 条「原因必须进得了文案」）+ 升级两条源码守卫。定向批 9 个文件共 **72 条全绿**。
  - 行为层：直连超时→自动改用镜像→真的落盘且**第一跳必是直连、命中后不再往下试**；
    全部候选失败→抛 `DictionaryDownloadException` 且 `attemptedUrls` 齐全、
    **temp 目录不留半个包**；**取消原样抛出**且 `isCancellation` 仍判真。
  - 归因层：五种 `DioErrorType` 各自归位；`badResponse` / `cancel` 不算传输失败
    （不触发回退）；dio 把 `SocketException` 塞进 `unknown` 时仍认作连接错误。
  - 文案层：下载阶段失败不得出现 "import failed"；超时原因里点名 host 且不含
    `DioError`；全文诊断带原始地址与 cause；多条失败逐条保留不互相覆盖。
  - 候选层：未接线时只有原址（与接线前逐字等价）；解析器返回空列表仍回落原址；
    **huggingface 不展开**（把上表的实测结论钉进测试，防止有人日后随手加个假镜像）。
  - 守卫升级：`dictionary_download_error_surfacing_guard_test.dart` /
    `dictionary_import_no_delay_guard_test.dart` 原本按变量名 `failedNames` 断言
    「失败有没有被收集」——**这个判据对根因 2 完全不敏感**（收集了，但收的是名字）。
    改为断言 `DictionaryTaskFailure(` + `error: e,` + `DictionaryTaskStage.download`。
  - **变异实测**（非空转）：删掉「取消原样抛出」那三行 → 定向批红在
    `isCancellation` 那条断言上；还原后源文件 sha256 与变异前逐字节一致。
- **未做 / 已知缺口**：
  - **huggingface 系列（wty）在国内仍然连不上**。本条只让它**如实报错**
    （点名主机 + 可复制全文），没有解决可达性。要解决只有两条路，都在
    `fushi.moe` 站点仓库、需要部署凭据：① Cloudflare Worker 反代
    `huggingface.co` 的 resolve 路径；② 把 wty 包镜像进 R2 并在 catalog 里加
    `mirrors` 字段（推荐包 manifest 已有同名字段可参考）。客户端侧的接入点已经
    留好——只要给 `dictionaryUrlCandidatesResolver` 多返回一个前缀即可，不需要再改
    下载器。
  - **真机复测未做**：本机无 Android 设备接入本次会话，Android 上「点下载 → 看到
    中文原因 → 点复制」这条路径只由单测与源码守卫覆盖。
