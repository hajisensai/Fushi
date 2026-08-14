#pragma once

// 通用位图呈现器的几何换算（纯逻辑，不碰 Win32）。
//
// 背景：游戏内查词的卡片位图此前只有一条落地路径——KiriKiri 的 TJS Layer。有脚本宿主的
// 引擎只此一家；CMVS / Siglus / Ren'Py / Unity / AOS 都没有等价物，于是这些引擎上 hit /
// input / frame 三通道和整条 Dart 编排层都是通的，唯独最后一步「把这块位图显示出来」没有
// 承载物。通用呈现器就是那个承载物：注入进程内的一个分层置顶窗口。
//
// 坐标域纪律（与 kirikiri 那条路径同一套，只是「视口」换了主体）：
//
//   * hit 与 frame 里的 anchor / glyph / view 尺寸，都在**游戏窗口客户区像素**域；
//   * 客户区左上角 = (0,0)，host 算避让与钳制时用的就是 view_w/view_h；
//   * 换算到屏幕只是加上客户区原点，全程不乘 dpr——dpr 只属于 Windows 窗口那一侧，
//     而这里两边都已经是物理像素。
//
// 钳制在**注入侧再做一次**，不是不信任 host，而是这两个数跨了进程边界：host 那侧算钳制
// 用的客户区尺寸取自上一帧，用户在两帧之间拖动/缩放窗口时它就是过期的。钳制到当前真实
// 客户区，卡片最多是贴边，永远不会飘到游戏窗口外面去。

#include <cstdint>

namespace fushi_voice_hook {

// 屏幕坐标矩形（右/下开区间）。
struct OverlayRect {
  int32_t left = 0;
  int32_t top = 0;
  int32_t right = 0;
  int32_t bottom = 0;

  int32_t width() const { return right - left; }
  int32_t height() const { return bottom - top; }
  bool empty() const { return right <= left || bottom <= top; }
};

// 卡片在屏幕上的位置。
//
//   client        : 游戏窗口客户区在屏幕上的矩形
//   anchor_x/y    : 卡片左上角，客户区坐标（host 给的）
//   card_w/card_h : 位图像素尺寸
//
// 返回空矩形表示「这帧不该显示」（尺寸非法，或客户区已经小到放不下任何东西）。
inline OverlayRect ComputeOverlayRect(const OverlayRect& client, int32_t anchor_x,
                                      int32_t anchor_y, int32_t card_w,
                                      int32_t card_h) {
  OverlayRect result;
  if (card_w <= 0 || card_h <= 0) return result;
  if (client.empty()) return result;

  // 先按客户区尺寸截断卡片本身：窗口比卡片还小的时候，宁可显示被截断的卡片，也不要把它
  // 摆到窗口外面（那正是用户看不见卡片、以为功能坏了的形态）。
  int32_t width = card_w;
  int32_t height = card_h;
  if (width > client.width()) width = client.width();
  if (height > client.height()) height = client.height();

  int32_t left = client.left + anchor_x;
  int32_t top = client.top + anchor_y;
  // 贴边钳制：先压右/下边界，再压左/上——顺序不能反，否则窗口比卡片小时左上会被右下推出去。
  if (left + width > client.right) left = client.right - width;
  if (top + height > client.bottom) top = client.bottom - height;
  if (left < client.left) left = client.left;
  if (top < client.top) top = client.top;

  result.left = left;
  result.top = top;
  result.right = left + width;
  result.bottom = top + height;
  return result;
}

// 屏幕点 -> 卡片局部坐标。IPC 契约要求输入事件带的是**已减去 anchor 的卡片局部坐标**
// （离屏 WebView2 那侧就是按卡片自己的坐标系合成的），所以这里减的是卡片左上角，不是
// 客户区原点。
inline void ScreenPointToCardLocal(const OverlayRect& card, int32_t screen_x,
                                   int32_t screen_y, int32_t* out_x,
                                   int32_t* out_y) {
  if (out_x != nullptr) *out_x = screen_x - card.left;
  if (out_y != nullptr) *out_y = screen_y - card.top;
}

// 点是否落在卡片矩形内（右/下开区间，与 OverlayRect 的约定一致）。
inline bool CardContainsScreenPoint(const OverlayRect& card, int32_t screen_x,
                                    int32_t screen_y) {
  if (card.empty()) return false;
  return screen_x >= card.left && screen_x < card.right &&
         screen_y >= card.top && screen_y < card.bottom;
}

}  // namespace fushi_voice_hook
