# 复习页卡面手势（2026-10-31）

取代 #2675（「点内容下方空白」的单一手势）：复习页卡面上的手势全部可配置，原生 Fushi 卡片与 WebView 卡面（模板卡 / 释义区）同一套判据。

## 手势与动作

- 手势（`SrsReviewGesture`，wire 名即偏好 JSON 的键）：`tap_left` / `tap_center` / `tap_right`（单击**空白**，按卡面区域横向三等分）、`double_tap`、`long_press`、`swipe_left` / `swipe_right` / `swipe_up` / `swipe_down`。
- 动作（`SrsReviewGestureAction`）：`none`、`show_answer`（只问题面）、`rate_again|hard|good|easy`（只答案面；「只留重来 / 良好」开着时困难 / 简单不生效，设置页注明）、`undo`、`replay_audio`、`toggle_toolbar`、`edit_note`、`bury`、`suspend`、`flag`。
- 每个动作都调复习页现成实现（`_showAnswer` / `_rate` / `_undoLast` / `_replayAudio` / `_toggleChrome` / `_onCardAction`），与按钮、快捷键同一条路径；评分 / 撤销在忙碌时不响应（同按钮禁用）。
- 问题面、答案面各一套映射。**默认 = 今天的行为**：三区单击都是切换顶栏，其余不绑。
- 键盘 / 手柄不变；iOS 不受限。

## 存储

一个偏好键 `srs_review_gestures`（`PreferenceKeys`），值是 `SrsReviewGestureMap.encode()` 的 JSON：

```json
{"v":1,"front":{"tap_left":"show_answer","tap_center":"toggle_toolbar",…},"back":{"swipe_left":"rate_good",…}}
```

- 两面都写全部已知手势（显式落盘，默认变了也不会悄悄改掉用户看到的映射）；偏好为空串 = 默认。
- 解码宽容、向前兼容：缺项 / 无法识别的动作 / 该面不可用的动作回默认；不认识的手势键原样保留并在再编码时写回（新版本加的手势不会被旧版本抹掉）。

## 识别器开关（arming）

`SrsReviewGestureMap.arming(side, hideHardEasy:)` 算出当前这一面要开哪些识别器（`SrsCardGestureArming`）。单击恒报；**没绑双击就不为等第二击推迟单击**，没绑长按 / 某轴滑动就完全不碰按住与拖动（滚动、拖选照旧）。开关随翻面、改映射、改「只留重来 / 良好」实时下发。

## 原生卡面：`SrsCardGestureRegion`

裸 `Listener`（不进手势竞技场，不抢子控件的点击），按命中路径分归属：

- 带点击处理的子控件（按钮、链接、`GestureDetector`，含 #2665 的点按显示翻译 / 例句注音揭示）→ 归子控件；
- `SrsCardGestureRegion.excluded` 圈出的子树（释义 WebView）→ 归页内脚本；
- 取词用掉的点按（`tapTookLookup`）→ 不报；
- 其余是空白。长按只认触屏 / 触控笔、只在空白且不在字上（字上的长按归选词）。
- 滑动只认触屏 / 触控笔；越过位移门时按主轴锁定，该轴没绑、或卡面的 `ScrollController` 还能往手指方向滚就不接管（那是滚动）；接管后卡面真的在这条轴上滚了（`ScrollUpdateNotification`）就作废。第二根手指落下 / 系统取消也作废。

## WebView 卡面：页内指针脚本 + 桥

`kSrsCardLookupScript` 是取词与手势**同一条**指针流水线（不另挂第二套监听抢同一次点按）。

- 门控：`window.__fushiSrsGestures = {"on":true,"doubleTap":…,"longPress":…,"swipeX":…,"swipeY":…}`（`srsCardGestureGateScript`）。没下发（`null`）时走旧路径原样——网页浏览器标签页共用本脚本。
- 点按归属：可点元素（`a` / `button` / 表单 / `summary` / `label` / 媒体 / `onclick` / `role=button` / contenteditable / `cursor:pointer`）归页面；点在字上（选区脚本 `getCharacterAtPoint` / 隐藏注音 `_hiddenFuriganaRubyAt`，与取词同一判据）归取词；有非空选区、弹窗开着时不报；其余才是空白。
- 滑动：同原生——只认触屏 / 触控笔、须在长按时限内起动、从输入框 / 媒体控件起手的拖动归它们；按主轴锁定后，落点所在的可滚动容器（含页面本身）还能往手指方向滚就不接管；接管后那条轴上真的滚了、或出现选区就回报 `cancel`。
- 桥：`callHandler('onSrsGesture', JSON)`，载荷 `{t, x, y, dx, dy, vx, vy, vw, vh}`：
  - `t` ∈ `tap` / `doubleTap` / `longPress` / `drag`（逐帧至多一次）/ `release`（带速度）/ `cancel`；
  - 坐标、位移、速度都是页面 CSS 像素，`vw` / `vh` 是视口尺寸；Dart 侧 `srsCardGestureFromPage` 按 WebView 盒子的逻辑尺寸换算，点按坐标再经盒子变换转成全局坐标（复习页按卡面区域算三分区）。

## 判定

- 三分区：`srsTapZoneOf`，以卡面区域（`srs-card-surface`）为准。
- 滑动：`srsClassifySwipe`——主轴位移 ≥ `kSrsSwipeCommitDistance`（96），或 ≥ `kSrsSwipeFlingMinDistance`（40）且主轴速度 ≥ `kSrsSwipeFlingVelocity`（700）；主轴须压过副轴 `kSrsSwipeAxisDominance`（1.5）倍；只认开着的轴。两种卡面都只回报原始位移 / 速度，由复习页统一判定。

## 反馈与动效

- 滑动途中：卡面按位移的 0.4 跟手（`SrsSwipeFollow`），中央显示松手会执行的动作（`SrsSwipeHintBadge`，评分用评分按钮同一套色调，两套设计系统各自配色）；只有朝着绑了动作的方向拖才有反馈；松手 / 作废弹回（`FushiMotion.release`）。墨水屏 / 系统「减弱动态效果」下卡面不移动、提示直接到位。
- 设置页「复习选项 → 手势」（`SrsReviewGesturesPage`，MD3 / Apple 两套）：说明与两组错峰进场（`FushiEntranceScope` + `FushiStaggeredEntrance`），行按压缩放（`FushiPressScale`），选动作走整页选择（选项多于行内下拉上限），右上角重置回默认。

## 冲突规则小结

| 情形 | 归属 |
|---|---|
| 点在链接 / 按钮 / 表单 / 可点元素上 | 页面 / 子控件 |
| 点在字上 | 取词（取词关掉时什么都不做，不算空白） |
| 点按显示翻译 / 注音（#2665） | 卡面自己（可点元素 / GestureDetector） |
| 查词弹窗开着 | 宿主关弹窗，不执行手势 |
| 有非空选区 / 正在拖选 | 选区 |
| 鼠标拖动 | 拖选，从不算滑动 |
| 容器还能往手指方向滚 | 滚动 |
| 没绑双击 | 单击立即报，不推迟 |

## 测试

- 纯逻辑：`fushi/test/srs/srs_review_gestures_test.dart`
- 原生识别区：`fushi/test/srs/srs_card_gesture_region_test.dart`
- 复习页接线（WebView 回报 + 原生真实指针 + 反馈）：`fushi/test/srs/srs_review_card_gestures_test.dart`
- 取词不被抢：`fushi/test/srs/srs_card_lookup_test.dart`「原生区卡面手势」
- 页内脚本（node）：`fushi/test/srs/srs_card_gesture_script_test.dart`
- 设置页：`fushi/test/srs/srs_review_gestures_page_test.dart`
