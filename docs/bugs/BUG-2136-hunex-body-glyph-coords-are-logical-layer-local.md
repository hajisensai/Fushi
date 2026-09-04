## BUG-2136 · WoH 正文字形 render x/y 是「1920×1080 逻辑空间的文本层局部坐标」，客户区映射已实测成立，只差层原点
- **报告**：2026-09-03（BUG-2135 判定 compose→texture→quad→sprite 五段全灭之后，改走「直接标定字形坐标系」这条路）
- **真实性**：✅ 真结论，**两种窗口尺寸 × 三条文本行 × 两张截图**交叉验证，不是推断。
- **推翻了本任务此前的一个错误结论**：我先前只抽到一条行（全部字形 `y` 相同），据此说「render x/y 是条带内局部坐标」。多抽几条后立刻证伪——同一帧内三条行的 `render_y` 分别是 23 / 104 / 266（行距 81，中间空一行故差 162），**是整个文本层内的坐标**，不是条带局部坐标。
- **实测数据**（WoH v1.0，pid=69132，helper x64 sha256 `83db73a6…39741997`）：
  | 行 | line_hash | 字形数 | render x | render y |
  |---|---|---|---|---|
  | 上一段第 1 行 | `0c05bb72…` | 12 | 24 起，步进 49.636 | 23 |
  | 上一段第 2 行 | `110db957…` | 18 | 24 起，步进 49.588 | 104 |
  | 当前行 | `b71b86fd…` | 28 | 24 起，步进 49.630 | 266 |
  字形位图恒 55×56，`advance24=54.88`。
- **映射结论（关键）**：把同一屏在两种客户区尺寸下各截一张图，把文字墨迹框按 `logical = pixel * (1920/client_w, 1080/client_h)` 归一化，两张图给出**逐位相同**的逻辑坐标：
  ```
  client 1874x1049 → 墨迹 top=398  left=325  right=1595 → 归一化 409.76 / 332.98 / 1634.15
  client 1254x709  → 墨迹 top=269  left=217  right=1067 → 归一化 409.76 / 332.25 / 1633.68
  ```
  且行距在逻辑空间里是 `Δ=81.3`（render Δ=81）、`Δ=160.7`（render Δ=162），**比例 1.00**。
  故成立：`client = (render + origin) × client_size / (1920, 1080)`，且 render 单位就是 1920×1080 逻辑像素（比例恰为 1，只在 1920×1080 空间成立；换算到引擎自己的 viewport 1788×1006 空间比例就变成 0.93，故可排除）。
  由三行墨迹反解出 `origin ≈ (304, 139)`（含各字形自身的墨迹内缩，故只是量级，不是最终值）。
- **[x] ① 已修复：origin 由宿主抓一帧自动解出，用户不需要手动框任何范围**
  - **hook→host**：`PublishLookupLayerLine()` 发布本行在层空间的包围盒 + 引擎设计分辨率
    （分辨率由引擎自己的 viewport/scale 全局反解，不写死：1788/0.93125=1920、1006/0.931481=1080）。
    发布的是**单独一行**的包围盒（按层空间 y 分行、取出墨字形最多的那一行），**不是整句
    的并集**：一句台词常折成两三行且各行缩进不同（行首常有一个全角空格），整句并集的 left
    来自缩进最小的那一行，而宿主在屏幕上只匹配到**其中一条**墨迹带——两边比的不是同一个
    东西，缩进差多少原点就偏多少，一个全角空格正好偏一格，真机上表现为「要往右一个字符
    才点得中想要的字」。包围盒还**只统计会出墨的字形**——行首的全角空格 U+3000 占一格却不画像素，算进去会让
    宿主用墨迹左边缘求出的原点整体右偏整整一格，真机上表现为「点第 N 个字查出第 N-1 个字」。
  - **host**：`SolveLookupLayerOrigin()`（`fushi/windows/runner/layer_origin_solver.cpp`）抓一帧客户区、
    按「均值+3σ」自适应阈值取亮像素、合成墨迹带、用**已知行宽**在候选里匹配（比值须落在
    0.80..1.06），再二维平移求解。**用中点而不是左上角**对齐：注入侧给的是字形格子边界、
    屏幕上量到的是墨迹边界，差着首尾字形各自的边距；拿中点则一阶抵消（实测残差 12px ≈
    0.26 格，远小于半格）。解不出来就什么都不发布，注入侧照旧 fail-closed。
    只在「注入侧已发过行、且本客户区尺寸还没解过」时跑一次；origin 是常量，缩放随尺寸变。
  - **host→hook**：`PublishLookupLayerOrigin()`；注入侧 `TransformHunexGgeProjectionByLayerOrigin()`
    用 `client = (layer + origin) * client/design` 直接投影，**整条 compose→texture→quad→sprite
    证据链不参与**（那四段已被真机计数证明在 WoH 正文上全灭）。落在客户区外的行拒绝发布。
- **真机验证（用户自己的 Fushi + 真 WoH，真词典在线）**：`status=activeNative`，点「精」弹出
  **精神**（せいしん）——分词正确、BCCWJ/Jiten/JPDBv2 词频 + アクセント辞典 + 明鏡/大辞泉两部释义齐全；
  台词 id 点击前后都是 #9，**剧情未推进**。全程没有任何手动校准。
- **原备注（已由上文取代）：需要按上述事实重建相关性锚点**。已排除的地方（都做过真机 dump，不是猜）：
  1. 字形 render item 自身前 0x70 字节（`render_item_words[28]` 全量 dump）：只有 `+0x10/+0x14` 与 `+0x18/+0x1c` 两份 (x,y)、一个逐字累加的 double 步进（30.4869/字）、一个常量 double 183.43 和两个模块内 vtable 指针，**无 (304,139) 量级的候选**。
  2. `render_item` 的另外三个参数（本轮新加的 `body_arg_words[3][32]` 探针）：arg2 与 arg3 是**同一个**指针，指向 `{ptr, ptr, 像素数据…}`；arg1 是 `{ptr 0x8003edfef0, ptr 0x80158b5470, 0, 0, 0x1001, …, 7}`。三者前 32 dword 内**无候选**。
  3. 引擎自己的 viewport/scale 全局（`rva.viewport=0x00596660`、`scale_x=0x0059c140`、`scale_y=0x0059c144`）：读出恒为 `{0,0,1788,1006}` + `0.93125/0.931481`，即 `1920×0.93125=1788`、`1080×0.931481=1006`，**与实际客户区无关也不随窗口尺寸变化**，不含原点。
  下一步候选（按代价排序）：① 沿 `outer={caller:0013340b,function:00130020}` 取该外层函数的 `this`，正文层对象大概率在那里；② `body_submit`（rva `0x00138640`）的入参；③ 承认 origin 是本作版式常量、收进 profile 并加运行期自校验（SOP 允许「引擎特例收进 profile/adapter」，但必须能被证伪）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/layer_origin_pixels_test.cpp`（ctest `fushi_layer_origin_pixels_test`，8 条合成夹具用例）：单带命中的 origin 数值与「用中点而不是左上角」、**多带同宽必须拒绝**（无 glyph_count 时直接拒、有 glyph_count时按列投影连通段数唯一消歧、并列仍拒）、宽度不符拒、全黑拒、全白拒（明亮场景不得把背景整片吃成一行字）、四种非法入参 fail-closed。变异实测：把多解判据退回「静默取 weight最大者」即转红。

  为此把像素判据从 `fushi/windows/runner/layer_origin_solver.cpp` 拆进`native/galgame_hook/include/layer_origin_pixels.h`（与 `host_executable_digest.h` 同一范式：需要被测的 host 逻辑放 include/，runner 用相对路径 include 真相源）——原先抓帧与像素分析焊死在 `SolveLookupLayerOrigin(HWND game, ...)` 一个函数里，结构上不可测，而它承载的正是「免手动校准」的全部算法。

  trace v16→v17 的 ABI 那半仍由既有守卫兜底：`hunex_gge_trace.h` 的 static_assert 与`tests/hunex_gge_lookup_test.cpp` 的镜像断言在编译期钉住，probe 侧镜像结构逐字段同序补齐（probe 与 helper 同源构建、版本不匹配即拒读）。

  *（此前这一条写的是「本轮改动是纯诊断探针、无行为不变式变化」——那是上一轮的说明，与本文件 ① 描述的新增求解器 + 双向 IPC 自相矛盾。）*
- **备注**：`engine-support.yaml` 的 `hunex_gge` 不因本条提升，仍 `implemented_unverified`。本条的价值是把 BUG-2135 留下的死胡同换成一个**只差一个二维常量**的问题：一旦拿到 origin，正文几何可以直接由字形矩形发布，**整条 compose → texture upload → quad → sprite 证据链都不需要**（那四段已被真机计数证明在 WoH 上分别是 0 次调用 / 描述符 0 成功 14 万失败 / 18.8 万次全部在形状校验早退 / 无源可配）。
- **关联**：[[BUG-2135]]（WoH 正文没有 compose 层）、[[BUG-2134]]（compose wrapper 锚点假阳性）、[[BUG-2129]]（WoH 真机边界台账）。
