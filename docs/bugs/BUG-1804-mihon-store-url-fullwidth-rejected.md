## BUG-1804 · 添加扩展仓库输入框无 URL 键盘类型，中文输入法全角标点被拒 INVALID_URL

- **报告**：2026-08-24（用户：Android release 通道 2.2.1-debug.12170，OnePlus 15 / CPH2747，真机 adb 复现）
- **现象**：漫画 → 导入 → 漫画扩展 → 「添加扩展仓库」，用中文输入法输入合法仓库地址，
  提交后弹「扩展错误：`MihonRuntimeException(INVALID_URL): Extension store URL is invalid`」。
  用户表述为「无法修改仓库地址」——因为仓库地址在 UI 上不可编辑（见 [BUG-1806](BUG-1806-mihon-store-url-not-editable.md)），
  想换地址只能删了重加，而重加这条路被本 bug 堵死，于是整体表现为「地址改不了」。
- **真实性**：✅ 真 bug。在用户真机上原样复现，且**必须切到日语键盘的半角英数模式才能输入成功**。

### 根因

`fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart:87-92` 的输入框没有声明键盘类型：

```dart
content: FushiTextField(
  controller: controller,
  labelText: t.mihon_store_url,
  hintText: 'https://example.org/repo.json',
  autofocus: true,      // ← 没有 keyboardType
),
```

缺省即 `TextInputType.text`，输入法按普通中文文本对待：Gboard 拼音模式下
`:` → `：`、`/` → `／`、`.` → `。`（实测截图见下）。而
`fushi/lib/src/media/manga/mihon/mihon_extension_store_client.dart:408-418` 的
`_validatedUri` 只做 `Uri.tryParse(rawUrl.trim())` + `hasAuthority`：

| 输入 | `Uri.tryParse` 结果 | 判定 |
|---|---|---|
| `https://github.com/keiyoushi/extensions/raw/repo/index.pb` | scheme=https auth=github.com | PASS |
| `https：//github.com/...`（全角冒号） | scheme=`` auth=`` | **INVALID_URL** |
| `https:／／github.com／...`（全角斜杠） | scheme=https auth=`` | **INVALID_URL** |
| `https://github．com/...`（全角句点） | auth=`github%EF%BC%8Ecom` | 假通过，后续 DNS 必失败 |

即：**用户拿默认中文输入法根本不可能把任何 URL 输进去**，且错误文案
「Extension store URL is invalid」完全没有指出问题出在全角字符上。

第三行那条尤其阴险——全角句点不会被 `hasAuthority` 拦住，会带着一个百分号编码的
垃圾域名一路走到网络层，最终报成一个与真实原因无关的网络错误。

同族：`fushi/lib/src/media/manga/aidoku/aidoku_repository_client.dart:73/82` 是同一套
`INVALID_URL` 判据（Aidoku 的输入框本身已声明 `keyboardType`，但归一化同样需要）。
全仓扫描后发现同一根因还有 10 处，见 [BUG-1807](BUG-1807-url-keyboard-missing-across-app.md)
——那一条同时补上了「消费端归一化 + 源码扫描守卫」两层收口，本 bug 的
`normalizeUrlInput` 就是被它复用的原语。

### 修复

- **[x] ① 已修复** — 两层，缺一不可：
  1. 新增 `fushi/lib/src/utils/net/url_input_normalizer.dart` 的 `normalizeUrlInput()`：
     全角 ASCII 区 U+FF01–U+FF5E 折回半角、表意句号 U+3002 → `.`、剔除非 ASCII 空白。
     **归一化发生在解析之前**——全角句点那条能骗过 `hasAuthority`，事后补救型的
     「解析失败再归一化」结构上抓不到它。
     接入点：`mihon_extension_store_client.dart:_validatedUri`（覆盖 addStore /
     refreshStores / editStoreUrl 全部入口）与 `aidoku_repository_client.dart:normalizeRepositoryUri`
     （同族），外加 `mihon_extensions_page.dart` 两个对话框的出口——在出口归一化，
     后续 `scheme == 'http'` 判定才不会因全角冒号判空而漏掉明文确认。
  2. `mihon_extensions_page.dart` 新增/编辑仓库两个输入框都声明
     `keyboardType: TextInputType.url`，让输入法一开始就给半角；归一化是兜底。
- **[x] ② 已加自动化测试** —
  - `fushi/test/utils/url_input_normalizer_test.dart`（13 条）：三种全角形态归一化后
    `authority` 均为 `github.com`；**反向用例**断言不归一化时前两种被拒、第三种带垃圾
    authority 通过——把「归一化是必需的，不是装饰」写死进断言；同时锁住
    「不动 path 里未编码的中文 / percent-encoding / 查询串」的边界。
  - `fushi/test/media/manga/mihon_store_row_actions_test.dart`：两个对话框的
    `keyboardType` 断言。
  - 变异实测：给 U+3002 分支加 `&& false` → 归一化测试红；删掉编辑框的
    `keyboardType` → 对应用例红。还原后两文件 sha256 与基线逐字节一致。
- **真机验证缺口（不要当成已验证）**：`normalizeUrlInput` 的行为由 13 条单测覆盖
  （含真机上实际撞到的三种全角形态），UI 两处 `keyboardType` 由 widget 测试断言。
  但**「Gboard 中文模式下 `TextInputType.url` 是否真的弹半角键盘」这一条没有真机跑过**：
  用户手机是 release 通道（versionCode 1001217000），本地 debug 包
  （1000122500）装不进去，`-d` 也被拒；不接受用卸载重装绕过（会丢用户全部阅读数据），
  也不接受硬拔高 versionCode（会让用户后续正式版更新装不上）。
  本机模拟器没有中文输入法，复现不了该条件。下次有可装的构建时补验。
- **备注**：与 [BUG-1805](BUG-1805-mihon-store-zero-extensions-silent.md)（拉到 0 条扩展静默无提示）、
  [BUG-1806](BUG-1806-mihon-store-url-not-editable.md)（仓库地址不可编辑）同批，三者叠加才构成用户
  「看不到插件、又改不了地址」的完整死局。
