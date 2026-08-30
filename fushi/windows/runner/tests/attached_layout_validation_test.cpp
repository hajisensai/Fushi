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
