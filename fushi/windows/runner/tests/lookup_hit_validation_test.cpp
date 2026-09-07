// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_overlayability_test.cpp 同一写法；无 assert 的文件也照写，免得
// 日后新增断言时又要重走一遍这个坑。
#undef NDEBUG

#include "../lookup_hit_validation.h"

#include <cassert>
#include <cstdint>
#include <limits>

int main() {
  const uint8_t source[] = {'A', 0xf0u, 0x9fu, 0x98u, 0x80u, 'B'};
  assert(fushi::lookup_hit_validation::ValidateUtf8SourceSpan(
      source, sizeof(source), 4u, 1u, 2u));
  assert(!fushi::lookup_hit_validation::ValidateUtf8SourceSpan(
      source, sizeof(source), 3u, 1u, 2u));
  assert(!fushi::lookup_hit_validation::ValidateUtf8SourceSpan(
      source, sizeof(source), 4u, 2u, 1u));
  assert(!fushi::lookup_hit_validation::ValidateUtf8SourceSpan(
      source, sizeof(source), 4u, 1u, 1u));

  const uint8_t overlong[] = {0xc0u, 0xafu};
  const uint8_t surrogate[] = {0xedu, 0xa0u, 0x80u};
  assert(!fushi::lookup_hit_validation::ValidateUtf8SourceSpan(
      overlong, sizeof(overlong), 1u, 0u, 1u));
  assert(!fushi::lookup_hit_validation::ValidateUtf8SourceSpan(
      surrogate, sizeof(surrogate), 1u, 0u, 1u));

  assert(fushi::lookup_hit_validation::IsProductionProviderPair(1u, 1u));
  assert(fushi::lookup_hit_validation::IsProductionProviderPair(2u, 5u));
  assert(fushi::lookup_hit_validation::IsProductionProviderPair(2u, 14u));
  assert(fushi::lookup_hit_validation::IsProductionProviderPair(2u, 15u));
  assert(!fushi::lookup_hit_validation::IsProductionProviderPair(1u, 15u));
  assert(fushi::lookup_hit_validation::IsProductionProviderPair(3u, 10u));
  assert(!fushi::lookup_hit_validation::IsProductionProviderPair(1u, 100u));
  assert(!fushi::lookup_hit_validation::IsProductionProviderPair(4u, 11u));
  assert(fushi::lookup_hit_validation::IsProviderLifecycleUsable(1u, 0u, 0u));
  assert(fushi::lookup_hit_validation::IsProviderLifecycleUsable(2u, 4u, 5u));
  assert(!fushi::lookup_hit_validation::IsProviderLifecycleUsable(2u, 0u, 5u));
  assert(fushi::lookup_hit_validation::IsCoordinateSpaceValid(1u));
  assert(fushi::lookup_hit_validation::IsCoordinateSpaceValid(4u));
  assert(!fushi::lookup_hit_validation::IsCoordinateSpaceValid(0u));
  assert(!fushi::lookup_hit_validation::IsCoordinateSpaceValid(5u));
  assert(!fushi::lookup_hit_validation::IsCoordinateSpaceValid(999u));

  assert(fushi::lookup_hit_validation::IsGeometryRectSane(10, 20, 30, 40, 100,
                                                          100));
  assert(!fushi::lookup_hit_validation::IsGeometryRectSane(
      std::numeric_limits<int32_t>::max(), 0, 2, 1,
      std::numeric_limits<int32_t>::max(), 1));
  assert(
      !fushi::lookup_hit_validation::IsGeometryRectSane(90, 0, 11, 1, 100, 1));
  return 0;
}
