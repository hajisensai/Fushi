#ifndef RUNNER_LAYER_ORIGIN_SOLVER_H_
#define RUNNER_LAYER_ORIGIN_SOLVER_H_

#include <windows.h>

#include <cstdint>
#include <string>

// BUG-2093：引擎层原点求解器（仅 Windows）。
//
// HUNEX/GGE 的正文字形位置是**文本层局部坐标**（引擎自己的设计分辨率单位，真机 WoH
// 为 1920x1080）。客户区映射
//     client = (layer + origin) * client / (design_w, design_h)
// 已在两种窗口尺寸 × 三条行上实测成立，`origin` 是每作一个常量——但**游戏内存里读不到
// 现成的**：字形 item 前 0x70 字节、render_item 另三个参数、body_submit 调用帧
// 0x000..0x180、viewport/scale 全局邻域四处都排除过。
//
// 所以由宿主抓一帧画面自己解：注入侧发布本行在层空间的包围盒，宿主量出同一行在屏幕上的
// 墨迹框，两者之差就是 origin。解出来一次就够（origin 是常量），失败就什么都不发布，
// 注入侧照旧 fail-closed 退回贴合层。
namespace fushi {

struct LayerOriginSolveResult {
  bool ok = false;
  int32_t origin_x = 0;
  int32_t origin_y = 0;
  // 失败原因（人类可读，进日志）；成功时为空。
  std::string reason;
  // 成功时一并带出用于复核的实测值。
  int32_t measured_left = 0;
  int32_t measured_top = 0;
  int32_t measured_right = 0;
  int32_t measured_bottom = 0;
};

// 用 |game| 客户区的一帧像素解层原点。
//
// |layer_*| 是注入侧发布的**本行**层空间包围盒，|design_*| 是引擎设计分辨率。
// 调用方必须保证 |game| 此刻在前台且未被遮挡（查词只在游戏前台时才激活，天然满足）。
LayerOriginSolveResult SolveLookupLayerOrigin(HWND game, int32_t layer_left,
                                              int32_t layer_top,
                                              int32_t layer_right,
                                              int32_t layer_bottom,
                                              uint32_t design_w,
                                              uint32_t design_h);

}  // namespace fushi

#endif  // RUNNER_LAYER_ORIGIN_SOLVER_H_
