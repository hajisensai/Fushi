// LucaSystem Win64 cText ABI. Resolve from engine structure, never an image
// hash, title, absolute address or screen-size constant. Shared projection,
// line matching and input state rules remain in luca_lookup_core.h.
#pragma once
#include "luca_lookup_core.h"
#include <limits>

namespace fushi_voice_hook::luca_x64 {

inline constexpr uint32_t kTextRowCapacity = 0x3Cu;
inline constexpr uint32_t kTextOriginX = 0x64u;
inline constexpr uint32_t kTextOriginY = 0x68u;
inline constexpr uint32_t kTextRowCount = 0x9Cu;
inline constexpr uint32_t kTextRows = 0x178u;
inline constexpr uint32_t kTextRowHead = 0x220u;
inline constexpr uint32_t kRowStride = 0xE0u;
inline constexpr uint32_t kRowRecordCount = 0x04u;
inline constexpr uint32_t kRowOriginX = 0x0Eu;  // i16, actual drawing origin
inline constexpr uint32_t kRowOriginY = 0x10u;  // float, actual drawing origin
inline constexpr uint32_t kRowOffsetY = 0x14u;  // i32, relative to row origin
inline constexpr uint32_t kRowRecords = 0xC8u;  // 64-bit pointer
inline constexpr uint32_t kRecordStride = 0x1Cu;
inline constexpr uint32_t kRecordUnit = 0x04u;
inline constexpr uint32_t kRecordX = 0x06u;
inline constexpr uint32_t kRecordW = 0x0Cu;
inline constexpr uint32_t kRecordH = 0x0Eu;
inline constexpr size_t kLayoutBodyBytes = 0x1100u;

// cText draw entry saves Win64 args 2/3, then seven nonvolatile registers.
// The stack size can change; RSI remains the saved this register. The first
// subobject is loaded via RCX and the next three via RSI.
inline constexpr int16_t kLayoutPrologueShape[] = {
  0x44,0x88,0x44,0x24,-1, 0x89,0x54,0x24,-1,
  0x53,0x55,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x57,
  0x48,0x81,0xEC,-1,-1,0x00,0x00,
  0x4C,0x8B,0x89,0x48,0x03,0x00,0x00,0x33,0xED,
  0x4C,0x89,0xB4,0x24,-1,-1,0x00,0x00,0x48,0x8B,0xF1,
  0x44,0x8B,0x35,-1,-1,-1,-1,
  0x44,0x89,0xB4,0x24,-1,-1,0x00,0x00,
  0x4D,0x85,0xC9,0x74,0x44,
  0x44,0x0F,0xB7,0x81,0xDE,0x04,0x00,0x00,
  0x0F,0xB7,0x91,0xDC,0x04,0x00,0x00,
  0x0F,0xB7,0x89,0xDA,0x04,0x00,0x00,
  0x0F,0xB7,0x86,0xD8,0x04,0x00,0x00,
  0x66,0x41,0x89,0x89,0xB8,0x10,0x00,0x00,
  0x41,0x89,0xA9,0xE0,0x10,0x00,0x00,
  0x66,0x41,0x89,0x81,0xB6,0x10,0x00,0x00,
  0x66,0x41,0x89,0x91,0xBA,0x10,0x00,0x00,
  0x66,0x45,0x89,0x81,0xBC,0x10,0x00,0x00,
};
inline constexpr int16_t kLayoutResetShape[] = {
  0x4C,0x8B,0x8E,-1,0x03,0x00,0x00,
  0x4D,0x85,0xC9,0x74,0x44,
  0x44,0x0F,0xB7,0x86,0xDE,0x04,0x00,0x00,
  0x0F,0xB7,0x96,0xDC,0x04,0x00,0x00,
  0x0F,0xB7,0x8E,0xDA,0x04,0x00,0x00,
  0x0F,0xB7,0x86,0xD8,0x04,0x00,0x00,
  0x41,0x89,0xA9,0xE0,0x10,0x00,0x00,
  0x66,0x41,0x89,0x81,0xB6,0x10,0x00,0x00,
  0x66,0x41,0x89,0x89,0xB8,0x10,0x00,0x00,
  0x66,0x41,0x89,0x91,0xBA,0x10,0x00,0x00,
  0x66,0x45,0x89,0x81,0xBC,0x10,0x00,0x00,
};
inline constexpr size_t kLayoutPrologueBytes = sizeof(kLayoutPrologueShape)/sizeof(int16_t);
inline constexpr size_t kLayoutResetBytes = sizeof(kLayoutResetShape)/sizeof(int16_t);
inline constexpr size_t kLayoutResetStride = 0x50u;

inline bool MatchesLayoutAt(const uint8_t* at, size_t bytes) {
  const size_t need = kLayoutPrologueBytes + 3u*kLayoutResetStride;
  if (at == nullptr || bytes < need ||
      !luca::MatchesShapeAt(at,kLayoutPrologueShape,kLayoutPrologueBytes)) return false;
  for (size_t i=0u; i<3u; ++i) {
    const uint8_t* block=at+kLayoutPrologueBytes+i*kLayoutResetStride;
    if (!luca::MatchesShapeAt(block,kLayoutResetShape,kLayoutResetBytes) ||
        block[3u] != 0x50u+static_cast<uint8_t>(i)*8u) return false;
  }
  return true;
}

inline bool ReadsRsiField(const uint8_t* body,size_t bytes,uint8_t opcode,uint32_t disp) {
  for (size_t i=0u;i+6u<bytes;++i) {
    if (body[i]!=opcode || (body[i+1u]&7u)!=6u) continue;
    const uint8_t mode=body[i+1u]&0xC0u;
    if (disp<0x80u && mode==0x40u && body[i+2u]==disp) return true;
    uint32_t actual=0u;
    if (mode==0x80u) {
      std::memcpy(&actual,body+i+2u,4u);
      if (actual==disp) return true;
    }
  }
  return false;
}
inline bool LayoutReadsModelFields(const uint8_t* body,size_t bytes) {
  return ReadsRsiField(body,bytes,0x8Bu,kTextRowCapacity) &&
      ReadsRsiField(body,bytes,0x8Bu,kTextRows) &&
      ReadsRsiField(body,bytes,0x8Bu,kTextRowHead) &&
      ReadsRsiField(body,bytes,0x3Bu,kTextRowCount) &&
      ReadsRsiField(body,bytes,0x6Eu,kTextOriginX) &&
      ReadsRsiField(body,bytes,0x8Bu,kTextOriginY);
}

// Row::GetRecord uses its own pointer and stride, independently of cText.
inline constexpr int16_t kRecordAccessorShape[] = {
  0x48,0x63,0xC2,0x48,0x6B,0xC0,0x1C,
  0x48,0x03,0x81,0xC8,0x00,0x00,0x00,0xC3,
};
inline constexpr int16_t kRowStrideShape[] = {
  0x4C,0x69,0xC8,0xE0,0x00,0x00,0x00,
};
inline bool ContainsRowStride(const uint8_t* body,size_t bytes) {
  const size_t length=sizeof(kRowStrideShape)/sizeof(int16_t);
  for (size_t i=0u;i+length<=bytes;++i)
    if (luca::MatchesShapeAt(body+i,kRowStrideShape,length)) return true;
  return false;
}

struct LayoutSites {
  uint32_t layout=0u;
  uint32_t design_width=0u;
  uint32_t design_height=0u;
};
inline constexpr int16_t kWidthShape[] = {
  0x44,0x8B,0x05,-1,-1,-1,-1,0xB8,0x67,0x66,0x66,0x66,
};
inline constexpr int16_t kHeightShape[] = {
  0x66,0x0F,0x6E,0x05,-1,-1,-1,-1,0x0F,0x5B,0xC0,0x0F,0x2F,0xC6,
};
inline bool RipTarget(uint32_t instruction,size_t length,const uint8_t* disp,uint32_t* out) {
  int32_t relative=0;
  std::memcpy(&relative,disp,4u);
  const int64_t target=static_cast<int64_t>(instruction)+static_cast<int64_t>(length)+relative;
  if (target<=0 || target>std::numeric_limits<uint32_t>::max()) return false;
  *out=static_cast<uint32_t>(target);
  return true;
}
// Width feeds a screen-relative draw calculation; height bounds rows before
// their render call. They must address adjacent engine DWORDs, uniquely.
inline bool ResolveDimensions(const uint8_t* body,size_t bytes,uint32_t rva,LayoutSites* out) {
  size_t widths=0u,heights=0u;
  for (size_t i=0u;i+sizeof(kWidthShape)/2u<=bytes;++i) {
    if (!luca::MatchesShapeAt(body+i,kWidthShape,sizeof(kWidthShape)/2u)) continue;
    if (++widths>1u || !RipTarget(rva+static_cast<uint32_t>(i),7u,body+i+3u,&out->design_width)) return false;
  }
  for (size_t i=0u;i+sizeof(kHeightShape)/2u<=bytes;++i) {
    if (!luca::MatchesShapeAt(body+i,kHeightShape,sizeof(kHeightShape)/2u)) continue;
    if (++heights>1u || !RipTarget(rva+static_cast<uint32_t>(i),8u,body+i+4u,&out->design_height)) return false;
  }
  return widths==1u && heights==1u && out->design_width<=UINT32_MAX-4u &&
      out->design_height==out->design_width+4u;
}
inline luca::LayoutSiteResult ResolveLayoutSite(const luca::CodeSpan* spans,size_t count,LayoutSites* out) {
  if (spans==nullptr || out==nullptr) return luca::LayoutSiteResult::kMissing;
  LayoutSites result;
  const uint8_t* found=nullptr;
  size_t available=0u,matches=0u,accessors=0u;
  for (size_t s=0u;s<count;++s) {
    const auto& span=spans[s];
    if (span.bytes==nullptr) continue;
    const size_t accessor_bytes=sizeof(kRecordAccessorShape)/sizeof(int16_t);
    for (size_t at=0u;at+accessor_bytes<=span.size;++at) {
      if (span.bytes[at]==0x48u &&
          luca::MatchesShapeAt(span.bytes+at,kRecordAccessorShape,accessor_bytes)) ++accessors;
    }
    for (size_t at=0u;at+kLayoutPrologueBytes<=span.size;++at) {
      if (span.bytes[at]!=0x44u || !MatchesLayoutAt(span.bytes+at,span.size-at)) continue;
      if (++matches>1u) return luca::LayoutSiteResult::kAmbiguous;
      found=span.bytes+at;available=span.size-at;result.layout=span.rva+static_cast<uint32_t>(at);
    }
  }
  if (matches==0u) return luca::LayoutSiteResult::kMissing;
  const size_t bytes=(std::min)(available,kLayoutBodyBytes);
  if (accessors!=1u || !ContainsRowStride(found,bytes) ||
      !LayoutReadsModelFields(found,bytes) || !ResolveDimensions(found,bytes,result.layout,&result))
    return luca::LayoutSiteResult::kFieldsMismatch;
  *out=result;
  return luca::LayoutSiteResult::kResolved;
}

// Normalize actual row drawing origins to the shared line mapper. This
// retains row alignment and animation offsets instead of assuming every
// row has the text object's unadjusted origin.
inline bool NormalizeRowOrigin(int16_t row_x,float row_y,int32_t relative_y,
                               int32_t text_x,int32_t text_y,int32_t* dx,int32_t* dy) {
  if (dx==nullptr || dy==nullptr || !std::isfinite(row_y) ||
      row_y < -luca::kMaxDesignSide || row_y > luca::kMaxDesignSide ||
      text_x < -luca::kMaxDesignSide || text_x > luca::kMaxDesignSide ||
      text_y < -luca::kMaxDesignSide || text_y > luca::kMaxDesignSide) return false;
  const int64_t x=static_cast<int64_t>(row_x)-text_x;
  const int64_t y=static_cast<int64_t>(static_cast<int32_t>(row_y))+relative_y-text_y;
  if (x < -luca::kMaxDesignSide || x > luca::kMaxDesignSide ||
      y < -luca::kMaxDesignSide || y > luca::kMaxDesignSide) return false;
  *dx=static_cast<int32_t>(x);*dy=static_cast<int32_t>(y);
  return true;
}

}  // namespace fushi_voice_hook::luca_x64
