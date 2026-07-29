#include "ipc_contract_descriptor.h"

#include <array>
#include <cstdio>
#include <cstring>

namespace {
bool Check(bool condition, const char* label) {
  if (!condition) std::fprintf(stderr, "ABI_FAIL %s\n", label);
  return condition;
}
}  // namespace

int main() {
  const IpcContractDescriptor native = NativeIpcDescriptor();
  const IpcContractDescriptor host = HostIpcDescriptor();
  if (!Check(std::memcmp(&native, &host, sizeof(native)) == 0,
             "descriptor") ||
      !Check(native.shared_version == 13, "shared_version") ||
      !Check(native.stable_ipc_version == 2, "ipc_version")) {
    return 1;
  }
  IpcContractDescriptor version_mutation = native;
  ++version_mutation.shared_version;
  IpcContractDescriptor layout_mutation = native;
  layout_mutation.shared_header_size += 8;
  if (!Check(std::memcmp(&version_mutation, &host, sizeof(host)) != 0,
             "descriptor_version_mutation") ||
      !Check(std::memcmp(&layout_mutation, &host, sizeof(host)) != 0,
             "descriptor_layout_mutation")) {
    return 1;
  }

  std::array<unsigned char, 65536> fixture{};
  const size_t size = NativeBuildIpcFixture(fixture.data(), fixture.size());
  if (!Check(size == native.shared_header_size, "fixture_size") ||
      !Check(HostAcceptsIpcFixture(fixture.data(), size), "roundtrip") ||
      !Check(HostFixtureSelectedThread(fixture.data(), size) ==
                 0x1122334455667788ull,
             "selected_thread") ||
      !Check(!HostAcceptsIpcFixture(fixture.data(), size - 1),
             "short_fixture")) {
    return 2;
  }

  // A v12/IPC-v1 helper is semantically incompatible and must be rejected.
  uint32_t old_version = 12;
  std::memcpy(fixture.data() + sizeof(uint32_t), &old_version,
              sizeof(old_version));
  if (!Check(!HostAcceptsIpcFixture(fixture.data(), size), "old_helper")) {
    return 3;
  }

  // Restore v13, then prove a native-only layout mutation is caught.
  std::memcpy(fixture.data() + sizeof(uint32_t), &native.shared_version,
              sizeof(native.shared_version));
  uint32_t bad_preview = 0;
  std::memcpy(fixture.data() + native.preview_offset_offset, &bad_preview,
              sizeof(bad_preview));
  if (!Check(!HostAcceptsIpcFixture(fixture.data(), size),
             "layout_mutation")) {
    return 4;
  }

  std::printf("ABI_OK arch_bits=%zu header=%zu selected=%zu preview=%zu\n",
              sizeof(void*) * 8, native.shared_header_size,
              native.selected_offset, native.preview_offset_offset);
  return 0;
}
