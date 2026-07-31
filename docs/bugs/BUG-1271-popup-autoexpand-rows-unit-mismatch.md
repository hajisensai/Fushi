## BUG-1271 · 自动展开默认值按本数写进行数槽位，出厂默认从3本变9本

- **报告**：2026-07-31（用户在 BUG-1264 结论上追问「为什么默认 3x3，不是默认 3 本吗，列数什么时候变成 3 了」）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/models/app_model.dart:4879`（修复前）

### 现象

查词弹窗出厂默认自动展开 **9 本**词典，而设置里那个滑块读数是 **3**。
用户拍板的意图是「第一行铺满即展开」= 列数那么多本 = 3 本。

### 根因

单位换算漏改，两个各自正确的改动叠在一起出的错：

1. TODO-1357：`popupDictionaryColumns` 出厂默认抬到 **3**（桌面 + 移动都是 3，真实生效列数
   再由 popup.js `effectiveDictColumns()` 按每列 ≥170px 视口收敛）。
2. 用户拍板 2026-07-14：自动展开默认「跟随最多列数」，即第一行铺满。当时这个偏好的单位是
   **本数**，所以 `popupAutoExpandDictionaries` 未显式设过时返回 `popupDictionaryColumns`
   —— 返回「列数那么多本」，正确。
3. TODO-845：把这个偏好的单位从「本数」改成「**行数**」，popup.js 侧
   `autoExpandCount() = rows × cols`（见 `assets/popup/popup.js` `autoExpandCount`）。
   **但 Dart 侧那个默认值没跟着换算**。

于是默认值变成 `cols` **行** × `cols` 列 = **cols² 本**：

| 最多列数 | 意图（第一行铺满） | 实际展开 |
|---|---|---|
| 1 | 1 本 | 1 本 |
| 3（出厂默认） | 3 本 | **9 本** |
| 4 | 4 本 | **16 本** |

TODO-845 当时的兼容性论证写的是「默认列数 1 时 rows × 1 === 旧的绝对本数，老用户零改变」——
这个论证的前提（列数默认 1）在 TODO-1357 把列数默认改成 3 之后就已经不成立了，只是没人回头核。

这也放大了 BUG-1264：per-dict 折叠开关在自动展开区内失效，而这个区默认就有 9 本，
基本覆盖一次查词能命中的全部词典 —— 用户的直接感受就是「折叠完全没用」。

### [x] ① 已修复

`app_model.dart` 的默认值改为 **1 行**：

```dart
int get popupAutoExpandDictionaries =>
    prefsRepo.hasExplicitPopupAutoExpandDictionaries
        ? prefsRepo.popupAutoExpandDictionaries
        : 1;
```

「跟随列数」的意图**没有变**，只是移到唯一正确的那一层：本数 = 1 × cols = cols 本，
乘法由 popup.js 的 `autoExpandCount` 单点负责。列数改成 4，默认展开就是 4 本（第一行），
不再是 16 本。

**存量显式值不做迁移**：`popup_auto_expand_dictionaries` 里已显式存过的值是按旧「本数」
语义写的，会被当行数读（存 3 → 3 行 × 3 列 = 9 本）。偏好没有写入时间戳，无法区分该值是
单位变更前还是变更后写的，任何自动换算都会误伤单位变更后设过的用户。该滑块在
「查词 → 自动展开词典数」可见可自调，故交由用户自行调整，不做静默数据迁移。

### [x] ② 已加自动化测试

`hibiki/test/pages/popup_layout_width_columns_test.dart` 的源码守卫改为断言默认 1 行，
并显式禁止把 `popupDictionaryColumns` 塞回行数槽位（附本 BUG 号与 cols² 的理由）。

⚠️ 这条守卫原本断言的是「默认 = popupDictionaryColumns」，**改动它是契约变更，不是回归**。
旧断言锁死的正是本 bug。

变异实测：把默认改回 `popupDictionaryColumns` → 守卫按预期变红
（`BUG-1271：单位是「行」，默认必须是 1 行` 断言失败）；恢复后绿。

### 备注

- 与 BUG-1264 同 PR 落地：1264 修「折叠开关被自动展开覆盖」，1271 修「自动展开区默认大了 3 倍」。
  两者独立成因，叠在一起才是用户看到的完整症状。
- 相邻可疑点（未改）：滑块只显示数字读数，用户看到「3」很难意识到那是 3 行 × 3 列 = 9 本；
  文案 `popup_auto_expand_dictionaries_hint` 已按「行」描述，但读数本身没有单位提示。
