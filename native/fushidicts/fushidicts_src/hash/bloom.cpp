#include "bloom.hpp"

#include <algorithm>
#include <bit>
#include <cstdint>
#include <cstring>
#include <stdexcept>

#include "../memory/memory.hpp"

namespace hash {
namespace {
constexpr uint64_t num_hashes = 7;
}

void bloom::load(const uint8_t* ptr) {
  uint64_t num_bits;
  std::memcpy(&num_bits, ptr, sizeof(uint64_t));
  uint64_t num_hashes;
  std::memcpy(&num_hashes, ptr + sizeof(uint64_t), sizeof(uint64_t));

  if (num_bits == 0 || (num_bits & (num_bits - 1)) != 0) {
    num_hashes_ = 0;
    mask_ = 0;
    bits_ = nullptr;
    return;
  }
  num_hashes_ = num_hashes;
  mask_ = num_bits - 1;
  bits_ = reinterpret_cast<const uint64_t*>(ptr + 2 * sizeof(uint64_t));
}

void bloom::build_to_file(const std::vector<uint64_t>& hashes, const std::string& path) {
  uint64_t num_bits = std::bit_ceil(std::max<uint64_t>(hashes.size() * 10, 64));
  uint64_t mask = num_bits - 1;

  size_t bits_size = num_bits / 8;
  auto out = memory::map_rw(path, 2 * sizeof(uint64_t) + bits_size);
  if (!out) {
    throw std::runtime_error("failed to create bloom filter");
  }

  std::memcpy(out.data, &num_bits, sizeof(uint64_t));
  std::memcpy(out.data + sizeof(uint64_t), &num_hashes, sizeof(uint64_t));
  auto* bits = reinterpret_cast<uint64_t*>(out.data + 2 * sizeof(uint64_t));
  std::memset(bits, 0, bits_size);

  for (uint64_t h : hashes) {
    auto h1 = static_cast<uint32_t>(h);
    auto h2 = static_cast<uint32_t>(h >> 32);
    for (uint64_t k = 0; k < num_hashes; k++) {
      uint64_t bit = (h1 + k * h2) & mask;
      bits[bit >> 6] |= 1ULL << (bit & 63);
    }
  }

  memory::unmap(out);
}
}
