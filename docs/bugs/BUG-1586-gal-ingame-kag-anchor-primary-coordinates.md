## BUG-1586 · 游戏内查词把 KAG 消息锚点误判为脱离 primary 导致字形恒不命中
- **报告**：2026-08-12（用户：）
- **真实性**：✅ 真 bug（沿修复前的 KAG 锚点选择与光标坐标换算路径核实）

### 根因

问题由两处同属「把几何相似误当对象身份」的错误叠加而成：

1. 修复前的 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:878-899` 要求文字锚点的
   `parent` 链必须经过 `kag.primaryLayer`。但 KAG 的 `back.messages[]` 可以位于 primary 的
   **兄弟子树**；它与 primary 共享更上层根节点，却不会经过 primary。本来合法的消息层因此被记为
   `kLookupDiagLayerDetached`，其偏移也不是严格的 primary 坐标，光标命中会稳定失败。
2. 修复前同文件 `:1379-1401` 在 fore/back 两页里按 `width/height` 找第一个同尺寸消息层。
   同页可以有多个同尺寸 message layer，且 fore/back 是逻辑消息层的双缓冲页；这条规则会把正在
   绘制的宿主映射到另一页或闲置的 `top=0` 层。后续即使坐标公式本身正确，起点也已经属于错误对象。

### 修复

- `fushiLookupComputeOffset` 分别以最多 32 层的有界遍历累加消息层与 primary 到共同根的绝对
  图层坐标；只有根对象相同才发布两者差值。兄弟子树因此可以严格换算，异根与父链环仍 fail closed。
- 锚点先从 `drawCh` 的真实宿主得到 `hostPage`，再把 `kag.currentNum` 投影到该宿主页的
  `messages[currentNum]`。旧/定制 KAG 没有可用 `currentNum` 时，才用 `kag.current` 的对象身份
  在 fore/back 中找到逻辑下标并投影回宿主页；不再用尺寸、名字或跨页「第一个」认领身份。
- primary 图像坐标（卡片落点）与 primary 图层坐标（高亮/命中）继续分开，避免把
  `imageLeft/imageTop` 混进父链坐标。

- **[x] ① 已修复** — 见本文件所在提交；根因实现位于
  `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:907-958,1631-1712`。
- **[x] ② 已加自动化测试** —
  `native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py`：共同根换算守卫、
  `hostPage → currentNum → 对象 identity 兜底` 锚点优先级守卫及逐项变异红例。
- **备注**：按用户要求本轮不运行自动化测试；bug 索引与支持矩阵生成器已同步。因此只证明根因与修复已落到源码，不能把
  KiriKiri 游戏内查词从 `implemented_unverified` 升级为真机已验证。
