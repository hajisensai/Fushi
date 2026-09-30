#pragma once

// RealLive 引擎身份：纯判据，输入由 adapter 注入（exe 文件字节流 + 目录文件存在谓词），
// 离线可单测，不碰真实文件系统。
//
// 判据只取引擎结构特征，不取 exe 名 / 摘要 / 标题（BUG-2153 同一教训：发行版会改名，
// 如 Key 的 Kinetic Novel 版把 RealLive 改名成 Kinetic.exe 且剧本打进 kineticdata.pak）：
//   ① 映像签名：exe 文件里以 **ASCII** 存放的 RealLive 配置/剧本名——`Gameexe.ini` 与
//      `Seen%04d.txt` / `Seen.txt`（RealLive 按这对文件加载配置与剧本，改名、换打包都不
//      影响引擎自己的字符串表）。
//   ② 目录签名：标准安装在 exe 同目录放 `Gameexe.ini` + `Seen.txt`。
// 两路任一成立即可；但出现 SiglusEngine 标志（`Gameexe.dat` / `Scene.pck` /
// `SiglusEngine`，ASCII 或 UTF-16）或 Siglus 目录签名时一票否决——Siglus 同出 VisualArt's，
// 它的 exe 以 **UTF-16** 带 `Gameexe.ini`（实测 planetarian HD Steam 版），不得被认成
// RealLive。KiriKiri 等其他引擎没有这组配置/剧本名。
//
// 已知边界：更早的 AVG32 同样使用 Gameexe.ini + SEEN.TXT 命名，映像签名无法区分二者；
// 这只影响身份标签，NWK 捕获仍要求 *.nwk 成员通过完整 NWA 校验。

#include <cstddef>
#include <cstdint>
#include <string>

namespace fushi_voice_hook {
namespace reallive {

constexpr uint32_t kImageMarkerGameexeIni = 1u << 0;
constexpr uint32_t kImageMarkerSeenScript = 1u << 1;
constexpr uint32_t kImageMarkerKoeConfig = 1u << 2;  // 仅诊断，不参与判定
constexpr uint32_t kImageMarkerSiglusVeto = 1u << 3;

// exe 文件扫描上界：RealLive 系 exe 实测 2~3 MB；超过上界的部分不扫（判据只会更保守）。
constexpr uint64_t kMaxImageScanBytes = 64ull * 1024ull * 1024ull;

struct ImageNeedle {
  const char* text;  // 小写 ASCII
  bool wide;         // true = 按 UTF-16LE 匹配
  uint32_t marker;
};

inline const ImageNeedle* ImageNeedles(size_t* count) {
  static const ImageNeedle kNeedles[] = {
      {"gameexe.ini", false, kImageMarkerGameexeIni},
      {"seen%04d.txt", false, kImageMarkerSeenScript},
      {"seen.txt", false, kImageMarkerSeenScript},
      {"#koefile", false, kImageMarkerKoeConfig},
      {"#init_koemode", false, kImageMarkerKoeConfig},
      {"gameexe.dat", false, kImageMarkerSiglusVeto},
      {"scene.pck", false, kImageMarkerSiglusVeto},
      {"siglusengine", false, kImageMarkerSiglusVeto},
      {"gameexe.dat", true, kImageMarkerSiglusVeto},
      {"scene.pck", true, kImageMarkerSiglusVeto},
      {"siglusengine", true, kImageMarkerSiglusVeto},
  };
  *count = sizeof(kNeedles) / sizeof(kNeedles[0]);
  return kNeedles;
}

inline uint8_t AsciiLower(uint8_t c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<uint8_t>(c - 'A' + 'a') : c;
}

// 流式扫描器：按块喂入 exe 字节，跨块边界的命中靠保留上一块尾部补上。标志位是集合，
// 同一命中被数两次无害。
class ImageSignatureScanner {
 public:
  void Feed(const uint8_t* data, size_t bytes) {
    if (data == nullptr || bytes == 0) return;
    // 边界区：上一块尾 + 本块头，只扫能跨界的起点。
    uint8_t joint[2 * kCarryBytes];
    const size_t head = bytes < kCarryBytes ? bytes : kCarryBytes;
    for (size_t i = 0; i < carry_; ++i) joint[i] = carry_bytes_[i];
    for (size_t i = 0; i < head; ++i) joint[carry_ + i] = data[i];
    Scan(joint, carry_ + head);
    Scan(data, bytes);
    // 新尾 = 「旧尾 + 本块」的末尾 kCarryBytes 字节。块比尾短时 joint 恰好就是旧尾+整块。
    if (bytes >= kCarryBytes) {
      for (size_t i = 0; i < kCarryBytes; ++i) {
        carry_bytes_[i] = data[bytes - kCarryBytes + i];
      }
      carry_ = kCarryBytes;
    } else {
      const size_t total = carry_ + bytes;
      const size_t keep = total < kCarryBytes ? total : kCarryBytes;
      for (size_t i = 0; i < keep; ++i) carry_bytes_[i] = joint[total - keep + i];
      carry_ = keep;
    }
  }
  uint32_t markers() const { return markers_; }

 private:
  // 最长针是 UTF-16 "siglusengine" 24 字节；32 足够覆盖任何跨界命中。
  static constexpr size_t kCarryBytes = 32;

  void Scan(const uint8_t* data, size_t bytes) {
    size_t count = 0;
    const ImageNeedle* needles = ImageNeedles(&count);
    for (size_t at = 0; at < bytes; ++at) {
      const uint8_t first = AsciiLower(data[at]);
      for (size_t n = 0; n < count; ++n) {
        const ImageNeedle& needle = needles[n];
        if (static_cast<uint8_t>(needle.text[0]) != first) continue;
        if (Matches(data + at, bytes - at, needle)) markers_ |= needle.marker;
      }
    }
  }

  static bool Matches(const uint8_t* data, size_t bytes,
                      const ImageNeedle& needle) {
    const size_t stride = needle.wide ? 2u : 1u;
    size_t i = 0;
    for (; needle.text[i] != 0; ++i) {
      const size_t at = i * stride;
      if (at + stride > bytes) return false;
      if (AsciiLower(data[at]) != static_cast<uint8_t>(needle.text[i])) {
        return false;
      }
      if (needle.wide && data[at + 1] != 0) return false;
    }
    return i > 0;
  }

  uint8_t carry_bytes_[kCarryBytes] = {0};
  size_t carry_ = 0;
  uint32_t markers_ = 0;
};

inline bool IsRealliveImageSignature(uint32_t markers) {
  const uint32_t required = kImageMarkerGameexeIni | kImageMarkerSeenScript;
  return (markers & required) == required &&
         (markers & kImageMarkerSiglusVeto) == 0;
}

// 标准安装的目录签名。file_exists(dir, name) 由调用方注入（生产 = Win32，测试 = 假表）。
template <typename FileExists>
bool DirectoryLooksLikeReallive(const std::wstring& dir, FileExists file_exists) {
  if (dir.empty()) return false;
  return file_exists(dir, L"Gameexe.ini") && file_exists(dir, L"Seen.txt");
}

struct IdentityInputs {
  bool image_measured = false;
  uint32_t image_markers = 0;
  bool reallive_directory = false;
  bool siglus_directory = false;
  bool siglus_executable = false;
};

}  // namespace reallive

inline bool MatchesRealliveProfile(const reallive::IdentityInputs& inputs) {
  if (inputs.siglus_executable || inputs.siglus_directory) return false;
  if (inputs.image_measured &&
      (inputs.image_markers & reallive::kImageMarkerSiglusVeto) != 0) {
    return false;
  }
  return inputs.reallive_directory ||
         (inputs.image_measured &&
          reallive::IsRealliveImageSignature(inputs.image_markers));
}

}  // namespace fushi_voice_hook
