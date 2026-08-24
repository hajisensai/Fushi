## BUG-1806 · 扩展仓库地址不可编辑，只能删了重加

- **报告**：2026-08-24（用户：Android release 通道 2.2.1-debug.12170，OnePlus 15 / CPH2747，真机 adb 复现）
- **现象**：用户表述「无法修改仓库地址」。漫画 → 导入 → 漫画扩展下的仓库卡片点上去毫无反应
  （真机实测：`input tap` 命中卡片，logcat 收到 touch，UI 无变化），卡片上只有一个删除按钮。
- **真实性**：✅ 真 bug（功能缺失，非回归）。

### 根因

编辑功能**从来没有实现过**，三重证据：

1. `fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart:621-637` 的 `FushiListItem`
   **没有 `onTap`**，`trailing` 只有删除按钮。
2. 全仓 grep `editStore` / `renameStore` / `updateStoreUrl` 在 `fushi/` 下零命中。
3. i18n 只有 `mihon_store_add` / `mihon_store_url` / `mihon_store_empty` / `mihon_store_refresh` /
   `mihon_store_remove`，**没有 edit**。

结构上的成因：`packages/fushi_core/lib/src/database/tables.dart:2446` + `:2461` 把
`indexUrl` 定义为 `MangaExtensionStores` 的**主键**（表注释原文：「仓库入口 URL 同时是稳定身份」）。
改地址 = 改主键，所以数据层天然只支持增/删。

**单独看这条只是不便，真正致命的是叠加**：

- 唯一的替代路径「删了重加」被 [BUG-1804](BUG-1804-mihon-store-url-fullwidth-rejected.md) 堵死
  （中文输入法输入的 URL 必被拒成 `INVALID_URL`）。
- `mihon_manager.dart:24-29`：默认仓库**只自动装配一次**，`kMihonDefaultStoreSeededPref` 置位后
  用户删掉官方仓库就永远不会被种回来。
- 于是「删掉官方 → 加了个坏仓库 → 想改回来」形成闭环死局：官方地址回不来，坏地址改不掉，
  新地址输不进去。用户手机上正是这个状态。

补充（次要）：`mihon_extensions_page.dart:438/444/450` 三个动作按钮共用
`onTap: manager.loading ? null : ...`，而 `_initialise` 是懒建（`app_model.dart:3569`）+
单次请求 30s / 连接 20s 预算（`mihon_extension_store_client.dart:317`、`utils/net/app_http.dart:47`），
所以在拉不动仓库的网络下，每个进程第一次进这个页面会连续灰 20-30 秒，连「添加仓库」都点不动，
加重「改不了」的体感。

### 修复

- **[x] ① 已修复** —
  1. `mihon_manager.dart` 新增 `editStoreUrl(oldIndexUrl, newIndexUrl, {allowInsecure})`。
     因为 `indexUrl` 是主键，实现必然是「删旧行 + 插新行」，但**顺序上先把新地址
     完整拉通（fetchStore + fetchExtensions）再动数据库**：拉不通就抛异常，旧行原封
     不动。反过来先删再拉，一旦新地址有问题，用户会同时失去旧仓库和新仓库。
     `enabled` / `sortOrder` 从旧行继承——改的是地址，不是这一行的其他状态，
     否则「改个地址」会顺手把仓库关掉或甩到列表末尾。
     落库身份取 `store.indexUrl`（解析后的）而非用户输入，因为 legacy 分支会跟随
     `index_v2` 重定向；并在此基础上查重，避免撞上另一条已存在的仓库主键。
  2. `mihon_extensions_page.dart` 的仓库卡片 `trailing` 由单个删除按钮改为
     编辑 + 删除，新增 `_editStore()` 对话框，预填当前地址
     （改地址的典型场景是同一仓库换路径，不该让用户从零重打长 URL），
     并同样声明 `keyboardType: TextInputType.url`（见 [BUG-1804](BUG-1804-mihon-store-url-fullwidth-rejected.md)）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_store_row_actions_test.dart`
  三条：编辑入口存在且预填当前地址 / 编辑框声明 URL 键盘 / 新增框同样声明。
  变异实测：删掉编辑框 `keyboardType` → 用例红；还原后 sha256 与基线一致。
- **未覆盖**：`manager.loading` 门导致首次进页面 20-30 秒按钮全灰这条（见上）
  **本轮没动**——它是超时预算与懒建时机的问题，与地址可编辑性正交，
  单独改动风险面更大，留待后续。
- **备注**：与 [BUG-1804](BUG-1804-mihon-store-url-fullwidth-rejected.md)、
  [BUG-1805](BUG-1805-mihon-store-zero-extensions-silent.md) 同批。
  编辑地址在数据层等价于「删旧行 + 插新行」（主键变更），实现时必须保证两步原子，
  且不能丢 `enabled` / 缓存目录等同行其他列。
