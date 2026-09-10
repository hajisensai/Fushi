## BUG-2439 · 关掉弹窗关闭动画后拖动仍跟手；底部停靠面板左右各缺 6px 不铺满
- **报告**：2026-09-10（用户：hajisensai）
- **真实性**：✅ 真 bug（两条独立症状，同一次报告）
  - ① 滑关跟手：`fushi/lib/src/utils/misc/swipe_dismiss_wrapper.dart:199`（`Transform.translate` 无条件跟手）与
    `fushi/lib/src/pages/implementations/dictionary_popup_layer.dart:1541`（正文横拖同款）。BUG-2405 只把**松手后**的
    补间时长归零（`popupDismissAnimationDuration`），跟手期的实时位移 + 淡出原样留着，于是「弹窗关闭动画」关掉后
    拖动仍看得见弹窗跟着手指滑一段才消失——与该开关副标题「关掉则瞬间关闭」不符。
  - ② dock 不铺满：`dictionary_popup_layer.dart:189`（`horizontalInset = inset.clamp(...)`，横纵共用一个 inset）
    + `:227`（`resolvePopupRect` 的 dock 分支 `inset: padding` 转发）。两个收口点传的都是**跟随模式**的贴边避让
    padding=6（`base_source_page.dart:559` / `dictionary_page_mixin.dart` 吃默认值），语义是「别贴着屏幕边缘弹出」，
    与 dock 的「整宽面板」相反，于是底部停靠面板左右各缺 6px。矩形铺满后卡片圆角（令牌 10）的四段弧仍会在屏幕
    左右缘露出背景，观感上还是没铺满。
- **[x] ① 已修复** — 提交见分支 `pr/popup-dismiss-instant`
  - 滑关：新增 `popupSwipeDismissIsInstant()` 收口（与 `popupDismissAnimationDuration` 同文件）。为真时两处滑关
    实现跟手期都不重绘、不挂 `Transform`/`Opacity`，抬手当帧按累计横向位移判阈值：过了直接 `onDismiss`，没过原地
    不动（没位移过，也就没有 spring-back 可弹）。判定时机仍在抬手，与 Hoshi Reader Android 一致（`LookupPopupHtml.kt`
    只监听 `touchstart`/`touchend`、不听 `touchmove`，全链路无补间）。墨水屏那条来源不变，仍只压补间时长、保留
    跟手方向反馈——两条来源正交。
  - dock：`dockedPopupRect` 把内边距**分轴**（新增 `horizontalInset`，默认 0；`inset` 只管纵向），`resolvePopupRect`
    的 dock 分支不再把 `padding` 转发进横向。`FushiPopupSurface` 新增 `borderRadius` 覆写（内圈半径逐角内缩描边、
    夹在 0），`DictionaryPopupLayer` 新增 `bottomDocked`，dock 态把圆角摊平；两个宿主传 `popupBottomDocked`。
- **[x] ② 已加自动化测试** — 10 条新用例，摘掉修复正好全红（判别力已验证）
  - `fushi/test/widgets/swipe_dismiss_wrapper_test.dart` — 新组「关掉动画后跟手期零位移」4 条：开着位移 200 /
    关掉恒 0 / 同一条拖动的对照 / 关掉时子树里一个 `Transform`·`Opacity` 都没有（不是靠 offset 0 假装不动）。
    另修既有「未过阈值」用例的断言（不再有 `Transform` 可取）。
  - `fushi/test/pages/dictionary_popup_layer_body_swipe_close_test.dart` — 正文横拖同款 4 条（与顶栏是两套独立
    实现，只测一边另一边回归时全绿）。
  - `fushi/test/pages/dictionary_popup_layer_test.dart` — dock 几何：左缘 0 / 宽 = 屏宽 / 右缘 = 屏宽；
    `resolvePopupRect` 传 padding=6 时横向仍铺满而纵向保留 6；横向 inset 显式给出仍生效（分轴而非删掉）。
  - `fushi/test/pages/dictionary_popup_dock_full_width_test.dart`（新文件）— dock 圆角摊平 / 跟随模式圆角不动 /
    两者确实不同 + 两条源码守卫（负半径夹取、两个宿主都传 dock 偏好）。
- **备注**：判定时机**没有**改成「越过阈值即刻关」——那会在拖到一半时误关，且与既有阈值语义（松手判定）冲突；
  hoshi 也是抬手才判。app 外查词窗的 JS 滑关（`popup_swipe_close_script.dart`）与桌面 barrier 横拖
  （`lookup_dismiss_barrier.dart`）本来就是纯判定、零跟手，不受本次改动影响。
