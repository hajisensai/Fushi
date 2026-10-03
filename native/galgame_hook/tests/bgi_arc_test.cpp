// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// BGI / Ethornell 归档解析与逐句语音包判据（bgi_arc.h）。
//
// 全部用合成字节：两代归档索引（PackFile 32 字节条目 / BURIKO ARC20 128 字节条目）与
// 64 字节 `bw  ` 包装头。字段布局与真实样本（2011 穢翼のユースティア Web 体験版
// PackFile、2016 千の刃濤、桃花染の皇姫 体験版 ARC20）逐字节核对过，但夹具里不含任何
// 游戏字节。

#include "bgi_arc.h"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace bgi = ::fushi_voice_hook::bgi;

namespace {

void PutLe32(std::vector<uint8_t>& out, size_t at, uint32_t value) {
  out[at] = static_cast<uint8_t>(value);
  out[at + 1] = static_cast<uint8_t>(value >> 8);
  out[at + 2] = static_cast<uint8_t>(value >> 16);
  out[at + 3] = static_cast<uint8_t>(value >> 24);
}

// 64 字节 bw 头 + "OggS" + 填充，共 member_size 字节。
std::vector<uint8_t> BwMember(uint32_t channels, uint32_t rate,
                              uint32_t member_size = 96) {
  std::vector<uint8_t> m(member_size, 0);
  PutLe32(m, 0, 64);
  std::memcpy(m.data() + 4, "bw  ", 4);
  PutLe32(m, 8, member_size - 64);
  PutLe32(m, 12, rate);  // sample_count：取 1 秒
  PutLe32(m, 16, rate);
  PutLe32(m, 20, channels);
  PutLe32(m, 48, 3);
  std::memcpy(m.data() + 64, "OggS", 4);
  return m;
}

struct Member {
  std::string name;
  std::vector<uint8_t> bytes;
};

// 按格式拼出完整归档（索引 + 首尾相接的成员）。
std::vector<uint8_t> BuildArchive(bgi::ArcFormat format,
                                  const std::vector<Member>& members) {
  const bool arc20 = format == bgi::ArcFormat::kArc20;
  const size_t entry = arc20 ? bgi::kArc20EntryBytes : bgi::kPackFileEntryBytes;
  const size_t name_bytes =
      arc20 ? bgi::kArc20NameBytes : bgi::kPackFileNameBytes;
  const size_t base = bgi::kArcHeaderBytes + entry * members.size();
  std::vector<uint8_t> out(base, 0);
  std::memcpy(out.data(),
              arc20 ? bgi::kArc20Signature : bgi::kPackFileSignature,
              bgi::kArcSignatureBytes);
  PutLe32(out, 12, static_cast<uint32_t>(members.size()));
  uint32_t relative = 0;
  for (size_t i = 0; i < members.size(); ++i) {
    const size_t record = bgi::kArcHeaderBytes + i * entry;
    assert(members[i].name.size() < name_bytes);
    std::memcpy(out.data() + record, members[i].name.data(),
                members[i].name.size());
    PutLe32(out, record + name_bytes, relative);
    PutLe32(out, record + name_bytes + 4,
            static_cast<uint32_t>(members[i].bytes.size()));
    relative += static_cast<uint32_t>(members[i].bytes.size());
  }
  for (const Member& m : members) {
    out.insert(out.end(), m.bytes.begin(), m.bytes.end());
  }
  return out;
}

// 与 adapter 的 ClassifyBgiVoiceArchive 同一走法：等距抽检成员、喂前 64 字节。
bool ClassifyInMemory(const std::vector<uint8_t>& archive) {
  bgi::ArcLayout layout;
  if (!bgi::ParseArcHeader(archive.data(), archive.size(), archive.size(),
                           &layout)) {
    return false;
  }
  bgi::VoiceArchiveTally tally;
  const uint32_t samples = bgi::VoiceClassifySampleCount(layout.count);
  for (uint32_t k = 0; k < samples; ++k) {
    const uint32_t i = bgi::VoiceClassifySampleIndex(layout.count, k);
    bgi::ArcEntry e;
    size_t head = 0;
    if (bgi::ReadArcEntry(archive.data(), archive.size(), layout, i,
                          archive.size(), &e)) {
      head = e.member_size < 64 ? e.member_size : 64;
    }
    tally.Add(archive.data() + (head == 0 ? 0 : e.member_offset), head,
              e.member_size);
  }
  return tally.IsVoiceArchive();
}

std::vector<Member> VoiceMembers(size_t n) {
  std::vector<Member> out;
  for (size_t i = 0; i < n; ++i) {
    out.push_back({"aiy01000" + std::to_string(1000 + i),
                   BwMember(1, 44100, 96 + static_cast<uint32_t>(i))});
  }
  return out;
}

void TestLayoutAndLookup(bgi::ArcFormat format) {
  const std::vector<uint8_t> archive = BuildArchive(format, VoiceMembers(3));
  const size_t entry = format == bgi::ArcFormat::kArc20
                           ? bgi::kArc20EntryBytes
                           : bgi::kPackFileEntryBytes;
  bgi::ArcLayout layout;
  assert(bgi::ParseArcHeader(archive.data(), archive.size(), archive.size(),
                             &layout));
  assert(layout.format == format);
  assert(layout.count == 3);
  assert(layout.data_base == bgi::kArcHeaderBytes + 3 * entry);
  assert(bgi::IsArcIdentityPrefix(archive.data(), archive.size(),
                                  archive.size()));

  // 第二个成员：data_base + 96。读偏移落在它的 bw 头或内嵌 Ogg 起点都能找回。
  const uint64_t second = layout.data_base + 96;
  bgi::ArcEntry e;
  assert(bgi::FindEntryForRead(archive.data(),
                               static_cast<size_t>(layout.data_base),
                               archive.size(), second, &e));
  assert(e.member_offset == second && e.member_size == 97);
  assert(std::strcmp(e.name, "aiy010001001") == 0);
  assert(bgi::FindEntryForRead(archive.data(),
                               static_cast<size_t>(layout.data_base),
                               archive.size(), second + 64, &e));
  assert(e.member_offset == second);
  // 索引区里的读偏移不属于任何成员。
  assert(!bgi::FindEntryForRead(archive.data(),
                                static_cast<size_t>(layout.data_base),
                                archive.size(), 4, &e));

  uint32_t ogg_offset = 0, ogg_size = 0;
  assert(bgi::ParseBwOggHeader(archive.data() + second, 97, 97, &ogg_offset,
                               &ogg_size));
  assert(ogg_offset == 64 && ogg_size == 33);
  bgi::BwHeader bw;
  assert(bgi::ParseBwHeader(archive.data() + second, 64, 97, &bw));
  assert(bw.header_bytes == 64 && bw.payload_bytes == 33 &&
         bw.sample_rate == 44100 && bw.channels == 1);
}

void TestMalformedIndexes() {
  std::vector<uint8_t> good =
      BuildArchive(bgi::ArcFormat::kPackFile, VoiceMembers(2));
  bgi::ArcLayout layout;
  // 头不全。
  assert(!bgi::ParseArcHeader(good.data(), 15, 0, &layout));
  assert(!bgi::ParseArcHeader(nullptr, 64, 0, &layout));
  // count == 0 / 超上界 / 索引比文件还大。
  {
    std::vector<uint8_t> a = good;
    PutLe32(a, 12, 0);
    assert(!bgi::ParseArcHeader(a.data(), a.size(), a.size(), &layout));
    PutLe32(a, 12, bgi::kMaxEntryCount + 1);
    assert(!bgi::ParseArcHeader(a.data(), a.size(), 0, &layout));
    PutLe32(a, 12, 1000);
    assert(!bgi::ParseArcHeader(a.data(), a.size(), a.size(), &layout));
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
    // 内存索引比 data_base 短：不认。
    assert(!bgi::IsArcIndex(a.data(), a.size()));
  }
  // 成员越界：size 超出文件。
  {
    std::vector<uint8_t> a = good;
    PutLe32(a, bgi::kArcHeaderBytes + 32 + 20, 1u << 30);
    bgi::ArcEntry e;
    assert(!bgi::FindEntryForRead(a.data(), a.size(), a.size(),
                                  a.size() - 8, &e));
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
    assert(!bgi::ReadArcEntry(a.data(), a.size(),
                              bgi::ArcLayout{bgi::ArcFormat::kPackFile, 2, 32,
                                             16, 16 + 64},
                              1, a.size(), &e));
  }
  // 越过 count 的条目、索引截断的条目读不到。
  {
    bgi::ArcLayout l;
    assert(bgi::ParseArcHeader(good.data(), good.size(), good.size(), &l));
    bgi::ArcEntry e;
    assert(!bgi::ReadArcEntry(good.data(), good.size(), l, 2, good.size(), &e));
    assert(!bgi::ReadArcEntry(good.data(), bgi::kArcHeaderBytes + 40, l, 1,
                              good.size(), &e));
  }
  // 自洽性：首条目 offset 不为 0 / 条目不首尾相接 / 名字空或不 NUL 结尾 / 控制字符。
  {
    std::vector<uint8_t> a = good;
    PutLe32(a, bgi::kArcHeaderBytes + 16, 4);
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
  }
  {
    std::vector<uint8_t> a = good;
    PutLe32(a, bgi::kArcHeaderBytes + 32 + 16, 1);
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
  }
  {
    std::vector<uint8_t> a = good;
    a[bgi::kArcHeaderBytes] = 0;
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
  }
  {
    std::vector<uint8_t> a = good;
    std::memset(a.data() + bgi::kArcHeaderBytes, 'A', 16);
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
  }
  {
    std::vector<uint8_t> a = good;
    a[bgi::kArcHeaderBytes + 1] = 0x07;
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
  }
  // 只给头、看不到任何条目：不能凭魔数认。
  assert(!bgi::IsArcIdentityPrefix(good.data(), bgi::kArcHeaderBytes,
                                   good.size()));
}

void TestForeignMagicsRejected() {
  // 相近但不是 BGI 的前缀：QLiE 的签名词、无空格的 PackFile、别家的 .arc。
  const char* foreign[] = {"PackFileVer3.1\0\0", "FilePackVer3.1\0\0",
                           "PackFile\x01\0\0\0\0\0\0\0", "BURIKO ARC10\x01\0\0\0",
                           "\0\0\x01\xba!\0\x01\0\x01\x80\xa2" "a\0\0\0\0"};
  for (const char* magic : foreign) {
    std::vector<uint8_t> a(256, 0);
    std::memcpy(a.data(), magic, 16);
    PutLe32(a, 12, 1);
    assert(!bgi::ParseArcHeader(a.data(), a.size(), a.size(), nullptr));
    assert(!bgi::IsArcIdentityPrefix(a.data(), a.size(), a.size()));
  }
  // elf AI6 voice.arc 形状：首 u32 就是条目数，没有魔数。
  std::vector<uint8_t> ai6(512, 0);
  PutLe32(ai6, 0, 3);
  assert(!bgi::IsArcIdentityPrefix(ai6.data(), ai6.size(), ai6.size()));
}

void TestBwHeader() {
  std::vector<uint8_t> m = BwMember(2, 48000);
  bgi::BwHeader bw;
  assert(bgi::ParseBwHeader(m.data(), m.size(), 96, &bw));
  assert(bw.channels == 2 && bw.sample_rate == 48000);
  assert(!bgi::ParseBwHeader(m.data(), 23, 96, &bw));   // 头不全
  assert(!bgi::ParseBwHeader(m.data(), 64, 23, &bw));   // 成员太小
  {
    std::vector<uint8_t> a = m;
    std::memcpy(a.data() + 4, "bx  ", 4);
    assert(!bgi::ParseBwHeader(a.data(), a.size(), 96, &bw));
  }
  {
    std::vector<uint8_t> a = m;
    PutLe32(a, 20, 0);  // 声道 0
    assert(!bgi::ParseBwHeader(a.data(), a.size(), 96, &bw));
    PutLe32(a, 20, 9);  // 声道越界
    assert(!bgi::ParseBwHeader(a.data(), a.size(), 96, &bw));
  }
  {
    std::vector<uint8_t> a = m;
    PutLe32(a, 16, 100);  // 采样率荒谬
    assert(!bgi::ParseBwHeader(a.data(), a.size(), 96, &bw));
  }
  {
    std::vector<uint8_t> a = m;
    PutLe32(a, 0, 96);  // header_bytes 吃掉整个成员
    assert(!bgi::ParseBwHeader(a.data(), a.size(), 96, &bw));
  }
}

void TestVoiceArchiveVerdict() {
  for (bgi::ArcFormat format :
       {bgi::ArcFormat::kPackFile, bgi::ArcFormat::kArc20}) {
    // 正向：全部单声道 bw → 语音包。
    assert(ClassifyInMemory(BuildArchive(format, VoiceMembers(5))));

    // BGM：head/loop 全立体声。
    assert(!ClassifyInMemory(BuildArchive(
        format, {{"bgm_0201_head", BwMember(2, 44100)},
                 {"bgm_0201_loop", BwMember(2, 44100, 200)}})));

    // SE：绝大多数立体声、夹着单声道短音效（两个真实样本的 SE 包都是这个形状）。
    // 单条成员级判据会把那条单声道收进来，包级判据不会。
    {
      std::vector<Member> se;
      for (int i = 0; i < 40; ++i) {
        se.push_back({"0" + std::to_string(1000 + i),
                      BwMember(i == 7 || i == 31 ? 1 : 2,
                               i == 31 ? 22050 : 44100)});
      }
      assert(!ClassifyInMemory(BuildArchive(format, se)));
    }

    // 混合包：单声道 bw + 非 bw 成员（图像 / 文本）。
    {
      std::vector<Member> mixed = VoiceMembers(4);
      std::vector<uint8_t> image(80, 0);
      std::memcpy(image.data(), "CompressedBG___", 15);
      mixed.push_back({"logo", image});
      assert(!ClassifyInMemory(BuildArchive(format, mixed)));
    }

    // 纯非音频包。
    {
      std::vector<uint8_t> dsc(80, 0);
      std::memcpy(dsc.data(), "DSC FORMAT 1.00", 15);
      assert(!ClassifyInMemory(BuildArchive(format, {{"ipl._bp", dsc}})));
    }

    // 过小的成员（放不下 bw 头）不算语音。
    assert(!ClassifyInMemory(BuildArchive(
        format, {{"a", BwMember(1, 44100)}, {"b", std::vector<uint8_t>(8)}})));
  }

  // 空统计不是语音包。
  assert(!bgi::VoiceArchiveTally().IsVoiceArchive());
}

void TestSampling() {
  // 不超过上限：逐个检查。
  assert(bgi::VoiceClassifySampleCount(5) == 5);
  for (uint32_t k = 0; k < 5; ++k) {
    assert(bgi::VoiceClassifySampleIndex(5, k) == k);
  }
  // 超过上限：等距、含首尾、单调、落在范围内。
  const uint32_t count = 10000;
  const uint32_t samples = bgi::VoiceClassifySampleCount(count);
  assert(samples == bgi::kMaxVoiceClassifyMembers);
  assert(bgi::VoiceClassifySampleIndex(count, 0) == 0);
  assert(bgi::VoiceClassifySampleIndex(count, samples - 1) == count - 1);
  uint32_t previous = 0;
  for (uint32_t k = 1; k < samples; ++k) {
    const uint32_t i = bgi::VoiceClassifySampleIndex(count, k);
    assert(i > previous && i < count);
    previous = i;
  }

  // 大 SE 包：抽检也要碰到立体声成员。
  std::vector<Member> big;
  for (int i = 0; i < 1500; ++i) {
    big.push_back({"s" + std::to_string(i), BwMember(i % 3 == 0 ? 1 : 2, 44100)});
  }
  assert(!ClassifyInMemory(BuildArchive(bgi::ArcFormat::kArc20, big)));
  // 大语音包：抽检后仍判语音。
  assert(ClassifyInMemory(BuildArchive(bgi::ArcFormat::kArc20,
                                       VoiceMembers(1500))));
}

}  // namespace

int main() {
  TestLayoutAndLookup(bgi::ArcFormat::kPackFile);
  TestLayoutAndLookup(bgi::ArcFormat::kArc20);
  TestMalformedIndexes();
  TestForeignMagicsRejected();
  TestBwHeader();
  TestVoiceArchiveVerdict();
  TestSampling();
  return 0;
}
