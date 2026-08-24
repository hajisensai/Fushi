## BUG-1827 · 查词弹窗英语音标溢出词典卡
- **报告**：2026-08-24（用户：「查词的字出了框」，截图为三栏并排查词结果，OALDPEX En-Cn 那栏有一块内容画到了栏外、压在左边 OALD 栏的正文上；用户澄清「不是嵌套弹窗，是正常查词，那个英语的音标会溢出」）
- **真实性**：⏳ **未定性**——机制尚未查实。已用实测**排除两条**看似成立的假设，记录在此避免以后重走弯路。

### 已排除：假设 A「IPA 是无断点长串，撑破/溢出列宽」

推理曾是：BUG-860 给 `a` 加过 `overflow-wrap: anywhere`（无空格长 URL 找不到断点会把卡片撑出右边界），而音标不是链接、不受该规则保护；`.glossary-group` 也没有 overflow 裁剪，故 IPA 串溢出。

**实测否定**。用 headless Edge 载入**完整** `popup.css`（不截片段拼探针），复刻 `popup.js layoutMasonry` 的几何约束（卡片 `position:absolute` + 硬设 `width`，列宽取最窄合法值 `DICT_COLUMN_MIN_WIDTH`=170px），用 `Range.getBoundingClientRect()` 量文本**实际渲染**矩形与卡片内容盒右边界之差：

| 用例 | `.glossary-group` 无 overflow-wrap | 加 `overflow-wrap: anywhere` |
|---|---|---|
| `UK: /ˈəʊvə(r)/` | 出框 0px（单行） | 出框 0px |
| `/ˌɪntəˈnæʃnəlaɪˈzeɪʃn̩ˈoʊvərˈəʊvə(r)/` | 出框 0px（**自行折成 2 行**） | 出框 0px（2 行） |

结论：IPA 串**本身就有断点**（`/`、`(`、`)`、`ˈ`、`ˌ` 在 UAX #14 下均可断行），根本不是「无断点长串」。加 `overflow-wrap` 对该现象零作用，故**已撤销**该改动，未留在代码里。

> 附带教训：第一版探针用 `scrollWidth - clientWidth` 量溢出，修复前后都得 0 —— 溢出的**内联文本**不增加块元素的 `scrollWidth`（它只反映滚动区域），那是个恒为 0 的无效测量。是「修复前也必须为真」的对照法暴露了它，否则会拿到一个假绿。

### 已排除：假设 B「弹窗宽度变化后 masonry 不重排，卡片停在旧位置」

推理曾是：`observeMasonryTargets()` 的 `ResizeObserver` **只观察 item、不观察 body**（`popup.js` 注释明写「容器宽度变化由 window resize 覆盖」），而 item 的 `width` 是 JS 硬设的固定 px，body 变窄时 item 尺寸不变 → observer 不触发 → 不重排 → 卡片按旧列宽停在旧 `translate` 上，整张卡偏出栏外。

**否定理由**：app 内查词弹窗**整个 WebView 就是弹窗**，弹窗宽度变化即 viewport 变化，`window.addEventListener('resize', scheduleMasonry)` 会正常触发重排。该假设只在浏览器扩展形态（弹窗是宿主页上的浮层 div，宽度变化不改 window 尺寸）下才可能成立，而用户报的是 app 内。

### 当前最强假设（未验证）：词典自带的结构化内容样式画到卡外

截图里那块越界内容的观感——不透明白底 + 圆角 + 投影 + A1 徽章 + 绿色 `Preposition` 标题框——**都不是 Hibiki 的样式**：`.glossary-group` 在 popup.css 里是**无 background 填充**的描边卡。这些视觉元素来自 OALDPEX 的 **Yomitan 结构化内容自带 style**。若其中含 `position:absolute/fixed`、负 margin 或超出列宽的固定 `width`，就会画到卡外、压住相邻列，而 `.glossary-group` 没有任何裁剪或包含块约束拦得住。

若成立，根因层修法应是**约束词典内容容器**（如给内容容器建立包含块 + `overflow: clip`，必要时用 `overflow-clip-margin` 给 ruby 上溢留边距），消除「词典自带样式可以画到卡外」这个特殊情况，而不是针对某本词典打补丁。

- **[ ] ① 未修复** — 机制未查实，不做猜测式修复。**需要一条区分信息**：换成别的英语词典（非 OALDPEX）查同一个词还出框吗？只有 OALDPEX 会 ⇒ 词典自带样式，按上面的容器约束修；所有词典都会 ⇒ 是 Hibiki 布局问题，需重新排查。另可用真机 DOM 取证直接定位越界元素（`docs/agent/computer-use-testing.md` / WebView2 浮窗视觉取证）。
- **[ ] ② 未加自动化测试** — 待根因定性后，在能复现该几何的最强层加（若为词典自带样式，可用完整 popup.css + 构造含 absolute/超宽元素的结构化内容做 headless 几何断言，探针脚手架已验证可行）。
- **备注**：本条**未做**猜测式修复。曾按假设 A 改过三镜像 `popup.css` + 重新生成两份 `content.css` 并配了守卫，实测否定后全部撤销，仓库未留下该改动。与同轮的 BUG-1798（查词浮层与控制条自动显隐竞态）是两回事，那条已修复并有守卫。
