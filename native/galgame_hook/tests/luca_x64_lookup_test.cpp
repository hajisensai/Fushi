// Keep checks alive under Release/NDEBUG.
#undef NDEBUG
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>
#include "../hook/adapters/luca_x64_lookup_core.h"
#ifdef _WIN32
#include <windows.h>
#include <tlhelp32.h>
#endif
namespace luca = fushi_voice_hook::luca;
namespace geom = fushi_voice_hook::luca_x64;
namespace {
void Put32(std::vector<uint8_t>& bytes,size_t at,uint32_t value) {
  std::memcpy(bytes.data()+at,&value,4u);
}
void Shape(std::vector<uint8_t>& bytes,size_t at,const int16_t* shape,size_t count) {
  for (size_t i=0u;i<count;++i) bytes[at+i]=shape[i]<0 ? 0u : static_cast<uint8_t>(shape[i]);
}
std::vector<uint8_t> Fixture(uint32_t rva,uint32_t width) {
  std::vector<uint8_t> bytes(geom::kLayoutBodyBytes,0x90u);
  Shape(bytes,0u,geom::kLayoutPrologueShape,geom::kLayoutPrologueBytes);
  for (size_t i=0u;i<3u;++i) {
    const size_t at=geom::kLayoutPrologueBytes+i*geom::kLayoutResetStride;
    Shape(bytes,at,geom::kLayoutResetShape,geom::kLayoutResetBytes);
    bytes[at+3u]=0x50u+static_cast<uint8_t>(i)*8u;
  }
  const uint8_t fields[] = {
    0x8B,0x5E,0x3C,                        // capacity
    0x48,0x8B,0xBE,0x78,0x01,0x00,0x00, // rows
    0x8B,0x9E,0x20,0x02,0x00,0x00,      // head
    0x3B,0xBE,0x9C,0x00,0x00,0x00,      // count
    0x66,0x0F,0x6E,0x46,0x64,            // integer x -> float
    0x44,0x8B,0x7E,0x68,                 // origin y
  };
  std::memcpy(bytes.data()+0x300u,fields,sizeof(fields));
  Shape(bytes,0x400u,geom::kWidthShape,sizeof(geom::kWidthShape)/2u);
  Put32(bytes,0x403u,width-(rva+0x400u+7u));
  Shape(bytes,0x500u,geom::kHeightShape,sizeof(geom::kHeightShape)/2u);
  Put32(bytes,0x504u,width+4u-(rva+0x500u+8u));
  Shape(bytes,0x700u,geom::kRecordAccessorShape,sizeof(geom::kRecordAccessorShape)/2u);
  Shape(bytes,0x730u,geom::kRowStrideShape,sizeof(geom::kRowStrideShape)/2u);
  return bytes;
}
void CheckResolver() {
  for (uint32_t rva : {0x1000u,0x9000u}) {
    auto bytes=Fixture(rva,0x8000u);
    luca::CodeSpan span{bytes.data(),bytes.size(),rva};
    geom::LayoutSites sites;
    assert(geom::ResolveLayoutSite(&span,1u,&sites)==luca::LayoutSiteResult::kResolved);
    assert(sites.layout==rva && sites.design_width==0x8000u && sites.design_height==0x8004u);
    span.size=geom::kLayoutPrologueBytes+geom::kLayoutResetStride*3u-1u;
    assert(geom::ResolveLayoutSite(&span,1u,&sites)==luca::LayoutSiteResult::kMissing);
  }
  auto bytes=Fixture(0x1000u,0x8000u);
  luca::CodeSpan spans[]={{bytes.data(),bytes.size(),0x1000u},{bytes.data(),bytes.size(),0x5000u}};
  geom::LayoutSites sites;
  assert(geom::ResolveLayoutSite(spans,2u,&sites)==luca::LayoutSiteResult::kAmbiguous);
  bytes[0x300u+2u]=0x3Du;
  assert(geom::ResolveLayoutSite(spans,1u,&sites)==luca::LayoutSiteResult::kFieldsMismatch);
  bytes=Fixture(0x1000u,0x8000u);spans[0].bytes=bytes.data();
  Put32(bytes,0x504u,0x8100u-(0x1000u+0x500u+8u));
  assert(geom::ResolveLayoutSite(spans,1u,&sites)==luca::LayoutSiteResult::kFieldsMismatch);
  bytes=Fixture(0x1000u,0x8000u);spans[0].bytes=bytes.data();
  Shape(bytes,0x600u,geom::kWidthShape,sizeof(geom::kWidthShape)/2u);
  assert(geom::ResolveLayoutSite(spans,1u,&sites)==luca::LayoutSiteResult::kFieldsMismatch);
  bytes=Fixture(0x1000u,0x8000u);spans[0].bytes=bytes.data();
  bytes[0x706u]=0x18u;  // stale glyph ABI must refuse
  assert(geom::ResolveLayoutSite(spans,1u,&sites)==luca::LayoutSiteResult::kFieldsMismatch);
  bytes=Fixture(0x1000u,0x8000u);spans[0].bytes=bytes.data();
  bytes[0x733u]=0x50u;  // stale row ABI must refuse
  assert(geom::ResolveLayoutSite(spans,1u,&sites)==luca::LayoutSiteResult::kFieldsMismatch);
  bytes=Fixture(0x1000u,0x8000u);spans[0].bytes=bytes.data();
  bytes[geom::kLayoutPrologueBytes+geom::kLayoutResetStride+3u]=0x50u;
  assert(geom::ResolveLayoutSite(spans,1u,&sites)==luca::LayoutSiteResult::kMissing);
}
void CheckActualRowOrigin() {
  int32_t dx=0,dy=0;
  assert(geom::NormalizeRowOrigin(130,245.75f,8,100,200,&dx,&dy));
  assert(dx==30 && dy==53);
  luca::Row row;row.offset_y=dy;
  row.records.push_back({0x3042u,static_cast<int16_t>(7+dx),20,22});
  std::vector<luca::LineGlyph> glyphs;
  assert(luca::MapRowsToLine(&row,1u,100,200,L"\u3042",&glyphs));
  assert(glyphs[0].rect.x==137 && glyphs[0].rect.y==253);
  assert(!luca::MapRowsToLine(&row,1u,100,200,L"\u3044",&glyphs));
  assert(!geom::NormalizeRowOrigin(0,std::numeric_limits<float>::quiet_NaN(),0,0,0,&dx,&dy));
  assert(!geom::NormalizeRowOrigin(0,std::numeric_limits<float>::infinity(),0,0,0,&dx,&dy));
  assert(!geom::NormalizeRowOrigin(0,0.0f,INT32_MAX,0,0,&dx,&dy));
}
#ifdef _WIN64
// Optional read-only live-image probe. Keeps code and rows in memory; never
// creates a dump, installs a hook or sends input. Only structural RVAs and
// dimensions are printed. This is resolver evidence, not E2E evidence.
int LiveProbe(DWORD pid) {
  HANDLE process=OpenProcess(PROCESS_VM_READ|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
  if (process==nullptr) return 10;
  HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,pid);
  MODULEENTRY32W module{};module.dwSize=sizeof(module);
  if (snapshot==INVALID_HANDLE_VALUE || !Module32FirstW(snapshot,&module)) {
    if(snapshot!=INVALID_HANDLE_VALUE) CloseHandle(snapshot);
    CloseHandle(process);return 11;
  }
  CloseHandle(snapshot);
  const uintptr_t base=reinterpret_cast<uintptr_t>(module.modBaseAddr);
  uint8_t headers[8192]{};SIZE_T got=0u;
  if (!ReadProcessMemory(process,reinterpret_cast<const void*>(base),headers,sizeof(headers),&got)) {
    CloseHandle(process);return 12;
  }
  const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(headers);
  if (dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<0 ||
      static_cast<size_t>(dos->e_lfanew)+sizeof(IMAGE_NT_HEADERS64)>got) {
    CloseHandle(process);return 13;
  }
  const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(headers+dos->e_lfanew);
  if (nt->Signature!=IMAGE_NT_SIGNATURE || nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64) {
    CloseHandle(process);return 14;
  }
  const auto* section=IMAGE_FIRST_SECTION(nt);
  if (reinterpret_cast<const uint8_t*>(section)+nt->FileHeader.NumberOfSections*sizeof(*section)>headers+got) {
    CloseHandle(process);return 15;
  }
  std::vector<std::vector<uint8_t>> storage;
  std::vector<luca::CodeSpan> spans;
  storage.reserve(nt->FileHeader.NumberOfSections);
  for (uint16_t i=0u;i<nt->FileHeader.NumberOfSections;++i) {
    if ((section[i].Characteristics&IMAGE_SCN_MEM_EXECUTE)==0u) continue;
    const size_t bytes=section[i].Misc.VirtualSize;
    const uint32_t rva=section[i].VirtualAddress;
    if (rva>=nt->OptionalHeader.SizeOfImage || bytes>nt->OptionalHeader.SizeOfImage-rva) {
      CloseHandle(process);return 16;
    }
    storage.emplace_back(bytes);
    if (!ReadProcessMemory(process,reinterpret_cast<const void*>(base+rva),storage.back().data(),bytes,&got) || got!=bytes) {
      CloseHandle(process);return 17;
    }
    spans.push_back({storage.back().data(),bytes,rva});
  }
  geom::LayoutSites sites;
  const auto result=geom::ResolveLayoutSite(spans.data(),spans.size(),&sites);
  int32_t width=0,height=0;
  const bool read=result==luca::LayoutSiteResult::kResolved &&
    sites.design_width<nt->OptionalHeader.SizeOfImage-4u &&
    sites.design_height<nt->OptionalHeader.SizeOfImage-4u &&
    ReadProcessMemory(process,reinterpret_cast<const void*>(base+sites.design_width),&width,4u,&got) && got==4u &&
    ReadProcessMemory(process,reinterpret_cast<const void*>(base+sites.design_height),&height,4u,&got) && got==4u;
  CloseHandle(process);
  std::printf("live resolver=%u layout=0x%x width_rva=0x%x height_rva=0x%x size=%dx%d\n",
    static_cast<unsigned>(result),sites.layout,sites.design_width,sites.design_height,width,height);
  return read && width>0 && height>0 && width<=luca::kMaxDesignSide && height<=luca::kMaxDesignSide ? 0:18;
}
#endif
} // namespace
int main(int argc,char** argv) {
  CheckResolver();CheckActualRowOrigin();
  std::puts("x64 lookup synthetic resolver and actual-row geometry checks passed");
#ifdef _WIN64
  if(argc==3 && std::strcmp(argv[1],"--probe")==0) return LiveProbe(static_cast<DWORD>(std::strtoul(argv[2],nullptr,10)));
#else
  (void)argc;(void)argv;
#endif
  return 0;
}
