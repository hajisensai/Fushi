# 2026-10 UI / 动效重做 · 效果图

由 `fushi/tool/design_preview/render_previews.sh`（Windows：`.ps1`）生成，用的是真实主题工厂与生产组件。
设计说明见 [`docs/specs/2026-10-02-ui-motion-redesign.md`](../../specs/2026-10-02-ui-motion-redesign.md)。

## 静态

| 桌面书架 · 浅色 | 桌面书架 · 深色 |
|---|---|
| ![](01_desktop_library_light.png) | ![](01_desktop_library_dark.png) |

| 手机书架 · 浅色 | 手机书架 · 深色 | 组件 · 浅色 / 深色 |
|---|---|---|
| ![](02_mobile_library_light.png) | ![](02_mobile_library_dark.png) | ![](03_components_light.png) ![](03_components_dark.png) |

## 动效（胶片 = 逐帧采样；GIF = 6 fps 慢放）

- 底栏药丸展开：![](10_motion_nav_pill.png) ![](motion_nav_pill.gif)
- 桌面页面转场（上：新共享轴；下：旧 Zoom）：![](11_motion_page_transition.png)
  新 ![](motion_page_transition_new.gif) 旧 ![](motion_page_transition_old.gif)
- 按压下沉与回弹：![](12_motion_press.png) ![](motion_press.gif)
- 书架首屏错峰进场：![](13_motion_stagger.png) ![](motion_stagger.gif)
- 曲线与时长：![](14_motion_curves.png)
