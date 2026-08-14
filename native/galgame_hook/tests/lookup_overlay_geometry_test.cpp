// 通用位图呈现器几何换算的离线单测（纯逻辑，不建窗口）。
//
// 这层要挡住的是「卡片飘到游戏窗口外面」这一类症状：用户看不见卡片，与「host 压根没投帧」
// 在现象上完全同形，真机上分不开。

#include <cstdio>

#include "lookup_overlay_geometry.h"

using fushi_voice_hook::CardContainsScreenPoint;
using fushi_voice_hook::ComputeOverlayRect;
using fushi_voice_hook::OverlayRect;
using fushi_voice_hook::ScreenPointToCardLocal;

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    ++g_failures;
  }
}

// 游戏窗口客户区：屏幕上 (100,50)，1280x720。
OverlayRect Client() {
  OverlayRect r;
  r.left = 100;
  r.top = 50;
  r.right = 100 + 1280;
  r.bottom = 50 + 720;
  return r;
}

}  // namespace

int main() {
  const OverlayRect client = Client();

  // 1) 正常一帧：客户区坐标 + 客户区原点。
  {
    const OverlayRect card = ComputeOverlayRect(client, 200, 300, 400, 240);
    Check(card.left == 300 && card.top == 350, "anchor is offset by client origin");
    Check(card.width() == 400 && card.height() == 240, "card keeps its pixel size");
  }

  // 2) 右下越界：贴边，不是飘出窗口。
  {
    const OverlayRect card = ComputeOverlayRect(client, 1200, 700, 400, 240);
    Check(card.right == client.right, "clamped to the right edge");
    Check(card.bottom == client.bottom, "clamped to the bottom edge");
    Check(card.width() == 400 && card.height() == 240, "clamping must not resize");
  }

  // 3) 负 anchor（host 用过期客户区尺寸算出来的）：压回左上，不越界。
  {
    const OverlayRect card = ComputeOverlayRect(client, -80, -40, 400, 240);
    Check(card.left == client.left && card.top == client.top,
          "negative anchor clamps to the client origin");
  }

  // 4) 窗口比卡片还小：截断卡片而不是把它摆到窗口外。
  {
    OverlayRect tiny;
    tiny.left = 0;
    tiny.top = 0;
    tiny.right = 320;
    tiny.bottom = 200;
    const OverlayRect card = ComputeOverlayRect(tiny, 10, 10, 400, 240);
    Check(card.left == 0 && card.top == 0, "tiny client pins the card to its origin");
    Check(card.width() == 320 && card.height() == 200,
          "card is truncated to the client size");
  }

  // 5) 非法尺寸 / 空客户区 -> 空矩形（这帧不显示）。
  {
    Check(ComputeOverlayRect(client, 0, 0, 0, 100).empty(), "zero width -> empty");
    Check(ComputeOverlayRect(client, 0, 0, 100, -1).empty(), "negative height -> empty");
    OverlayRect collapsed;
    Check(ComputeOverlayRect(collapsed, 0, 0, 100, 100).empty(),
          "empty client -> empty");
  }

  // 6) 输入事件坐标：减的是**卡片左上角**，不是客户区原点。IPC 契约要的是卡片局部坐标，
  //    减错原点会让离屏 WebView2 收到系统性偏移的鼠标位置——表现是卡片里点不中链接。
  {
    const OverlayRect card = ComputeOverlayRect(client, 200, 300, 400, 240);
    int32_t x = 0;
    int32_t y = 0;
    ScreenPointToCardLocal(card, 310, 370, &x, &y);
    Check(x == 10 && y == 20, "screen point maps to card-local coordinates");
    Check(CardContainsScreenPoint(card, 300, 350), "top-left corner is inside");
    Check(!CardContainsScreenPoint(card, 700, 590), "bottom-right corner is exclusive");
    Check(!CardContainsScreenPoint(card, 299, 350), "just left of the card is outside");
  }

  if (g_failures == 0) {
    std::printf("lookup_overlay_geometry_test: all checks passed\n");
    return 0;
  }
  std::printf("lookup_overlay_geometry_test: %d check(s) failed\n", g_failures);
  return 1;
}
