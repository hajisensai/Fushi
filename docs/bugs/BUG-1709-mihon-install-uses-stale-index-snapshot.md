## BUG-1709 · 默认 keiyoushi 仓库安装扩展报 STORE_HTTP_404：安装用的是过期索引快照
- **报告**：2026-08-18（用户：手机装漫画扩展报 `MihonRuntimeException(STORE_HTTP_404): Extension store request failed`，用户确认**用的是默认 keiyoushi 仓库、没自己加过仓库**）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/mihon/mihon_manager.dart:299`（修复前的 `prepareStoreInstall`）——它直接拿传进来的 `MihonAvailableExtension.apkUrl` 去下载，而那个对象来自 `MihonManager.available`。

  `available` 是**远端索引的内存快照**：没有任何缓存表（`MangaExtensionStores` 只存仓库元数据，扩展目录不落库），只在 `_initialise()` 里调一次 `_refreshStores()` 填充，此后除非用户手动下拉刷新就再也不动。

  而快照里的 `apkUrl` 指向的是**短寿命资源**。2026-08-18 实测 keiyoushi：
  - `index.pb` 完全正常（`github.com/.../raw/repo/index.pb` 302 → raw 200，gzip 解压 676KB）；
  - 索引里 1368 条 apk 直链全部指向 GitHub release 资产，与仓库当时保留的 7 个 release 的 2736 个资产**逐条对账，一条不缺**；
  - 但那 7 个 release **全部产于 08-16**（tag `a76c957-{0,1,2}` / `afa591f-{0,1,2}` / `5e06c41`）——上游只保留最近 7 个 release，旧 tag 连同资产一起删，**保留窗口只有一两天**。

  两件事合起来就是用户的症状：一份新鲜索引不可能 404（已对账证明），所以 404 的必然是过期快照。手机上 Flutter 进程在后台活几天很常见，那时快照里的**每一条**直链都指向已被删除的 tag，点哪个扩展装都是 `STORE_HTTP_404`。

  同一个快照还会以另一个面孔发作：索引版本号往前走后，下载到的 APK 版本比快照新，`_prepareInstallBytes` 的 `versionCode` 比对判定 `METADATA_MISMATCH`。两个症状同一个根因——**下载时刻的真相源是索引，不是几天前的快照**。

- **[x] ① 已修复** — 新增 `MihonManager._resolveInstallTarget()`：`prepareStoreInstall` 在下载前**重新解析一次该仓库的索引**，按 `packageName` 取当次索引里的条目，用它的 `apkUrl` 下载、也用它做 `expected` 元数据比对；顺手把刷出来的目录写回 `available` 并 `notify`（卡片上的版本号不该跟马上要装的东西对不上，`index_v2` 会让最终 indexUrl 与库里那行不同，两个地址的旧条目都清）。索引刷不到就**直接失败，不回退快照**：下一步本来就要联网下 APK，「索引拿不到却假装能装」只会把同一个 404 推到下一步，还多一条分支。条目在当次索引里已消失则抛 `EXTENSION_GONE`（「扩展已从仓库下架」是可操作信息，`STORE_HTTP_404` 不是）。这不是「404 了再重试一次」的补丁，而是把安装的输入从快照换成当次索引。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_manager_install_test.dart` 加 2 条：① `store install downloads from a freshly resolved index`（喂一份 apkUrl 已轮换的新索引 + 一份直链指向「已删除 release」的旧快照，断言请求过的 URL 里**没有**旧直链、有新直链，且 proposal 的 `expected` 是新版本号）；② `store install reports an extension pulled from the repository`（新索引里已无该包 → 断言 `EXTENSION_GONE` 而不是去下旧直链）。变异实测两发两中，还原后源文件 sha256 与变异前逐字节一致（`83425ba3…`）：
  - `downloadApk(target.apkUrl)` → `downloadApk(extension.apkUrl)`：① 由绿转红；
  - `throw EXTENSION_GONE` → `return snapshot`（静默回退快照）：② 由绿转红。
- **备注**：
  - 代价是每次安装多一次索引请求（keiyoushi 约 100KB gzip）。安装是低频动作，换掉的是「整类快照过期故障」，值。
  - 同轮另修 [BUG-1707](BUG-1707-mihon-store-legacy-index-v2.md)（legacy 分支吞掉 `index_v2`，填 `index.min.json` 的仓库安装必 404）与 `STORE_HTTP_*` 报错补上失败地址——后者是本轮排查最耗时的地方：旧文案 `Extension store request failed` 不写地址，同一个 404 可能是索引、扩展列表或 APK 直链，只能靠猜。配合 [BUG-1703](BUG-1703-manga-extension-error-truncated-toast.md) 的可复制错误对话框，下次用户报错能直接看出是哪个地址。
  - **未做**：给扩展目录加持久化缓存表。当前「进程内快照 + 冷启动刷新」在安装侧已经不再是真相源，列表侧显示旧版本号只是显示问题，加表会引入新的失效语义，等真有需求再说。
  - **未做真机复测**：本轮全部是单测 + 对真实 keiyoushi 索引/release 的实测对账，没在手机上跑修复后的包复现原始失败路径。
