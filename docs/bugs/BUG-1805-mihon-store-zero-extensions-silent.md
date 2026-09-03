## BUG-1805 · 仓库拉到 0 条扩展时静默空列表，无任何提示

- **报告**：2026-08-24（用户：Android release 通道 2.2.1-debug.12170，OnePlus 15 / CPH2747，真机 adb 复现）
- **现象**：漫画 → 导入 → 漫画扩展下挂着一张 Keiyoushi 仓库卡片，卡片下面什么都没有。
  点刷新按钮，界面**毫无变化**：没有加载态、没有错误、没有「0 条」说明。用户表述为
  「看不到仓库里面的插件」。
- **真实性**：✅ 真 bug。真机 logcat 显示刷新确实发起了 `github.com` 的 DNS 查询，
  之后无任何输出；同一台机器上 `curl` 实测该仓库 HTTP 200。

### 根因

用户配的仓库是 `https://github.com/yuzono/manga-repo/raw/repo/index.min.json`。
在用户手机上实测（`adb shell curl`，走 FlClash tun0）：HTTP 200，**765 字节**，内容是

```json
[ { "name": "Outdated App",            "pkg": "eu.kanade.tachiyomi.extension.all.keiyoushi", ... },
  { "name": "Update to Mihon 0.20.1+", "pkg": "eu.kanade.tachiyomi.extension.all.mihon",     ... } ]
```

即上游把 legacy 路径 `index.min.json` 掏空成了两条**版本门控哨兵**（官方
`keiyoushi/extensions` 的同名文件同样是 765 字节的这两条），真索引在 `index.pb`
（102,981 字节）/ `index.json`（1,387,205 字节，1375 个扩展）。

**「HTTP 200 但目录为空」是一条完全无声的路径。** 静默来源（子代理审计 + 复核）：

| file:line | 分支 | 表现 |
|---|---|---|
| `mihon_extension_store_client.dart:254-255` | current 格式仓库既无内嵌目录又无 `extensionListUrl` → `return const []` | 完全静默 |
| `mihon_extension_store_client.dart:270-271` | 外部列表 JSON 缺 `extensions` 键 → `?? const <Object?>[]` | 完全静默 |
| `mihon_extension_store_client.dart:654` | `.pb` 里读不到 field 1 → 空 list，不抛 | 完全静默 |
| `mihon_manager.dart:279` | 上述路径**成功**返回，于是把上一轮的 `lastError` 清空 | 连残留线索都被抹掉 |
| `mihon_extensions_page.dart:640` | `available` 与 `installed` 皆空时连语言/搜索筛选栏都不渲染 | 页面上只剩一张干净的仓库卡片 |

于是最终形态是：**一张没有任何错误标记的 Keiyoushi 卡片 + 零插件 + 刷新无反馈**，
用户拿不到任何可行动信息，也无从判断是网络问题、地址问题还是 app 坏了。

对比：`mihon_manager.dart:282-304` 的**异常**路径至少会把 `lastError` 写进卡片副标题第二行。
真正没有出口的恰恰是「请求成功但结果为空」这条。

### 修复

- **[x] ① 已修复** — `mihon_extensions_page.dart` 的仓库卡片副标题把「启用中 + 无
  lastError + 该仓库在 `available` 里一条都没有」这个状态显式渲染成
  `t.mihon_store_zero_extensions`（新增 i18n key，17 语言齐全）。
  三态用 switch 表达而非层层 if，优先级明确：**真实错误 > 零扩展 > 干净 URL**——
  已有 lastError 时不能被零扩展提示顶掉，那条信息量更大；停用的仓库不报零扩展，
  它本来就不该拉。
  刻意**没有**改成往 DB 的 `lastError` 里塞文案：那个字段存的是英文异常串，
  塞进去既不可本地化，也会让「这次刷新真的失败了」和「刷新成功但空」两种状态混淆。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_store_row_actions_test.dart`
  四条：零扩展给出说明 / 有扩展时不提示 / lastError 优先 / 停用仓库不提示。
  变异实测：把零扩展分支改回 `store.indexUrl` → 用例红；还原后 sha256 与基线一致。
- **备注补充**：i18n key 走 `tool/i18n_sync.dart --add` 落 17 个 JSON。`strings.g.dart`
  **没有**用 `dart run slang` + `dart format` 重新生成——入库文件是 short style
  （旧 dart format 产物），而本机 Dart 3.12 只能产出 tall style，整文件重排会是
  40 万行 diff（实测）。改为按现有风格精确插入 118 行（17 语言 × 2 key ×
  getter + flatMap case），与历史提交规模一致（BUG-1767 为 138 行），
  `flutter test test/i18n` 23 条全绿验证完整性。
- **备注**：与 [BUG-1804](BUG-1804-mihon-store-url-fullwidth-rejected.md)、
  [BUG-1806](BUG-1806-mihon-store-url-not-editable.md) 同批。
  另注意 BUG-1722 的定位是「让默认仓库存在且失败可见」，明确不负责让它一定拉得到；
  本 bug 补的是它没覆盖的「拉到了、但是 0 条」这一格。
