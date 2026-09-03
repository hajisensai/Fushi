// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_overlayability_test.cpp 同一写法；无 assert 的文件也照写，免得
// 日后新增断言时又要重走一遍这个坑。
#undef NDEBUG

#include "../attached_layout_validation.h"

#include <cassert>
#include <limits>

int main() {
  using fushi::attached_layout_validation::IsLayoutValid;

  assert(IsLayoutValid(0.045, 0.0, 1.0, "left", "top", 0.0));
  assert(IsLayoutValid(0.5, -0.05, 0.5, "center", "center", 0.25));
  assert(IsLayoutValid(0.1, 0.1, 4.0, "right", "bottom", 0.1));

  assert(!IsLayoutValid(0.0, 0.0, 1.0, "left", "top", 0.0));
  assert(!IsLayoutValid(0.501, 0.0, 1.0, "left", "top", 0.0));
  assert(!IsLayoutValid(0.1, -0.051, 1.0, "left", "top", 0.0));
  assert(!IsLayoutValid(0.1, 0.101, 1.0, "left", "top", 0.0));
  assert(!IsLayoutValid(0.1, 0.0, 0.499, "left", "top", 0.0));
  assert(!IsLayoutValid(0.1, 0.0, 4.001, "left", "top", 0.0));
  assert(!IsLayoutValid(0.1, 0.0, 1.0, "trailing", "top", 0.0));
  assert(!IsLayoutValid(0.1, 0.0, 1.0, "left", "far", 0.0));
  assert(!IsLayoutValid(0.1, 0.0, 1.0, "left", "top", 0.251));
  assert(!IsLayoutValid(std::numeric_limits<double>::quiet_NaN(), 0.0, 1.0,
                        "left", "top", 0.0));
  return 0;
}
