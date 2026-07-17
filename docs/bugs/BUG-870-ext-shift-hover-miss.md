## BUG-870 · 浏览器扩展 Shift 悬停查词约 80% 不弹（机器相关，本机未复现）

- **报告**：2026-07-17（用户转述他人反馈）
- **现象**：浏览器扩展中，光标移到单词上按住 Shift，约 80% 的词不弹查词窗；只有少数（约 20%，多为"指针恰好落在字正中"）能弹。报告人机器复现，用户自己机器复现不了，两边词典配置相同。
- **真实性**：⏳ 待失败机器诊断证据（本机与用户机均无法复现，属机器/环境相关，未复现记一条）。

### 真实代码路径（已定位）

- 扩展源码真相源：`tools/browser-extension/`，构建副本 `hibiki/assets/browser_extension/`（逐字节一致）。
- 唯一查词入口：`content.js:1196-1246` 的 `document` 级 `mousemove` 监听（Shift = `HIBIKI_MOD='shiftKey'`，`content.js:21`）。命中取词全靠 `window.hoshiSelection.getCharacterAtPoint(x,y)`（`vendor/selection.js`）。
- 命中核心两条分支 `getCaretRange`（`selection.js:74-102`）：
  - **新分支** `document.caretPositionFromPoint`（Chrome 128+ / Firefox）→ 取 caret。
  - **旧分支** 无 `caretPositionFromPoint` 时 → `elementFromPoint().closest('p,div,span,ruby,a')` + 逐字扫描 + 回退 `caretRangeFromPoint`。
- 两条分支最后都汇到 `getCharacterAtPoint`（`selection.js:104-138`）的**严格矩形复核**：只在 `[caret, caret-1, caret+1]` 三个偏移里，用 `inCharRange`（`selection.js:60-72`）对 `getClientRects()` 的矩形做**闭区间严格包含**（`x>=rect.left && x<=rect.right && y>=rect.top && y<=rect.bottom`）；三格都框不住指针 → 返回 `null` → 不弹。**这是"只在字正中命中、大量落空"的共同失败点。**

### 根因候选（按可疑度）

1. **浏览器版本分叉**：`caretPositionFromPoint` 仅 Chrome 128+。报告人若旧 Chrome → 走旧分支，命中率与新分支差异极大 → 符合"你的机器不复现、他的 80% 失败"。
2. **页面 zoom / 坐标换算错位**：目标页用 CSS `zoom` 或缩放时，旧内核下 `getClientRects` 与 `clientX/clientY` 坐标系错位，严格闭区间复核只在偏移≈0 处偶中 → 表现为约 80% 落空。
3. **iframe 边界**：`manifest.json` 主 content_scripts 未设 `all_frames:true`，正文在 `<iframe>` 的站点整块无效（但那样应是 100% 失败，不是 80%）。
4. **严格复核本身过紧**：`inCharRange` 闭区间 + 只查 3 个偏移，行高/字距/竖排下指针落在字形矩形外即弃。

### 诊断（发给报告人在失败页面主世界 Console 粘贴）

```js
// 按住 Shift 划过一个"没反应"的词后立即运行：
(() => {
  const d = document.documentElement.dataset;
  return {
    脚本版本: d.hibikiCs,                 // 确认加载的是新版而非缓存旧版
    浏览器: navigator.userAgent,
    caretPositionFromPoint支持: !!document.caretPositionFromPoint,  // false=走旧分支(候选1)
    devicePixelRatio: window.devicePixelRatio,
    最后指针: d.hibikiMove,
    命中字符: d.hibikiCaret,              // 'null'=selection.js就没命中(候选1/2/3)
    取到的词: d.hibikiTerm,               // 有词但不弹=问题在sendLookup/服务端
  };
})();
```

判读：
- `命中字符 === 'null'` → 卡在 `getCharacterAtPoint`（候选 1/2/3/4），比对 `caretPositionFromPoint支持` 与 UA 定位分支；zoom 看候选 2。
- 有 `命中字符` 和 `取到的词` 但不弹 → 问题在 `hibikiSendLookup`（`content.js:1253-1288`）或后端，与命中无关。
- `脚本版本` 为空/旧 → 报告人加载的是缓存旧扩展，先重载扩展。

### 待办

- **[ ] ① 未修复** — 待诊断证据定位分支后根因修（若候选 1/2 属实，倾向让旧分支与严格复核容错化，而非只在字正中命中）。
- **[ ] ② 未加自动化测试** — 现有守卫 `tools/browser-extension/shift-hover.test.js`；修复后在此加"指针落在字边缘/旧分支/zoom"的命中回归。
- **备注**：本机 + 用户机均无法复现，机器相关。取证前不盲改，避免引入空白处误弹（严格复核的存在本是为了拒绝空白/行间误触发）。
