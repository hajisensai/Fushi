#undef NDEBUG
#include <windows.h>
#include "siglus_legacy_resource.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_legacy_resource;
int checks=0;
void Check(bool ok) {
  ++checks;
  if (!ok) { std::fprintf(stderr,"FAIL check %d\n",checks); std::abort(); }
}
struct Image {
  std::vector<uint8_t> bytes=std::vector<uint8_t>(0x20000,0xcc);
  exact_lookup::LoadedPeImage view{};
  uintptr_t voice,play,resource,formatter,string_ctor,ctor,ogg,crt,archive,read;
  std::vector<std::pair<uintptr_t,exact_lookup::MaskedPattern>> parts;
  std::vector<std::pair<uintptr_t,uintptr_t>> edges;
  explicit Image(uintptr_t shift=0,uintptr_t base=0x14000000) {
    view.base=bytes.data(); view.size=bytes.size(); view.absolute_base=base;
    view.machine=IMAGE_FILE_MACHINE_I386; view.pointer_bits=32;
    view.section_count=2;
    view.sections[0]={bytes.data()+0x1000,0x17000,0x1000,
                     IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    view.sections[1]={bytes.data()+0x18000,0x8000,0x18000,IMAGE_SCN_MEM_READ};
    voice=0x1000+shift; play=0x3000+2*shift; resource=0x5000+3*shift;
    formatter=0x7000+4*shift; string_ctor=0x9000+5*shift;
    ctor=0xb000+6*shift; ogg=0xd000+7*shift; crt=0x10000+8*shift;
    archive=0x12000+9*shift; read=0x14000+10*shift;
    parts={{voice,kVoice0.pattern()},{play,kPlay0.pattern()},
      {resource,kResource0.pattern()},{resource+562,kResource1.pattern()},
      {resource+1123,kResource2.pattern()},{resource+1687,kResource3.pattern()},
      {resource+2247,kResource4.pattern()},{resource+2808,kResource5.pattern()},
      {formatter,kFormatter0.pattern()},{string_ctor,kStringCtor0.pattern()},
      {ctor,kOggCtor0.pattern()},{ogg,kOggOpen0.pattern()},
      {crt,kCrtFormatter0.pattern()},{archive,kArchiveOpen0.pattern()},
      {read,kArchiveRead0.pattern()}};
    for (const auto& p:parts) std::memcpy(bytes.data()+p.first,p.second.bytes,p.second.size);
    edges={{voice+0x73,play},{play+0xb6,resource},
      {resource+0x28b,string_ctor},{resource+0x294,formatter},
      {formatter+0x73,crt},{resource+0x710,string_ctor},
      {resource+0x731,archive},{resource+0x7e0,read},
      {resource+0x82d,read},{resource+0x93b,ctor}};
    for (const auto& e:edges) Call(e.first,e.second);
    Literal(resource+0x279,0x18000,L"z%04d.ovk");
    Literal(resource+0x6fd,0x18100,L"rb");
    Literal(ogg+0x33,0x18200,L"rb");
    Absolute(ctor+0x42,0x18400); Absolute(0x18404,ogg);
  }
  void Call(uintptr_t at,uintptr_t target) {
    Check(bytes[at]==0xe8);
    const int32_t delta=static_cast<int32_t>(target-at-5);
    std::memcpy(bytes.data()+at+1,&delta,4);
  }
  void Absolute(uintptr_t at,uintptr_t target) {
    const uint32_t value=static_cast<uint32_t>(view.absolute_base+target);
    std::memcpy(bytes.data()+at,&value,4);
  }
  template<size_t N> void Literal(uintptr_t at,uintptr_t target,const wchar_t (&s)[N]) {
    Absolute(at,target); std::memcpy(bytes.data()+target,s,sizeof(s));
  }
  bool Resolve(SiglusLegacyResourceMappingProfile* out) {
    return ResolveSiglusLegacyResourceMappingProfile(view,voice,out);
  }
  void Reject() {
    SiglusLegacyResourceMappingProfile out; out.voice_entry_rva=123;
    Check(!Resolve(&out)); Check(out.voice_entry_rva==0 && out.payload_return_rva==0);
  }
};
void TestResolver() {
  Image image;
  SiglusLegacyResourceMappingProfile out;
  Check(image.Resolve(&out));
  Check(out.voice_entry_rva==image.voice && out.play_entry_rva==image.play &&
        out.resource_entry_rva==image.resource && out.ogg_open_rva==image.ogg &&
        out.payload_return_rva==image.resource+0x988 &&
        out.resource_return_rva==image.play+0xbb && out.ogg_vtable_rva==0x18400);
  Image moved(0x25,0x24000000);
  Check(moved.Resolve(&out));
  Check(out.resource_entry_rva==moved.resource && out.ogg_open_rva==moved.ogg);
  // Whole connected Resource body is checked; perturb fixed instructions in
  // every span, including alternative-format and failure branches between gates.
  for (const auto& p:image.parts) {
    for (size_t i=0;i<p.second.size;i+=13) {
      if (!p.second.mask[i]) continue;
      image.bytes[p.first+i]^=1;
      image.Reject();
      image.bytes[p.first+i]^=1;
    }
  }
  for (const auto& e:image.edges) {
    image.Call(e.first,e.second+1); image.Reject(); image.Call(e.first,e.second);
  }
  // The exact divisor, multiply-back radix, row stride/member column and
  // three-argument virtual call are semantic gates, not loose byte hints.
  for (uintptr_t off:{0x99u,0xadu,0x84au,0x852u,0x983u}) {
    image.bytes[image.resource+off]^=1; image.Reject();
    image.bytes[image.resource+off]^=1;
  }
  // Branch destinations are invariant within a compiler layout. Redirecting
  // the key rejection, format dispatch, member equality or open-success edge
  // must fail; these immediates must never be treated as image relocations.
  for (uintptr_t off:{0x94u,0x270u,0x84cu,0x863u,0x98cu}) {
    image.bytes[image.resource+off]^=1; image.Reject();
    image.bytes[image.resource+off]^=1;
  }
  // Another independently matching entry is ambiguous even if its later body
  // is incomplete. No nearest-to-admitted-entry or first-match fallback.
  for (const auto& p:image.parts) {
    if (p.first>image.resource && p.first<image.resource+0xc93) continue;
    if (p.first==image.ctor || p.first==image.crt) continue;
    std::memcpy(image.bytes.data()+0x16000,p.second.bytes,p.second.size);
    image.Reject();
    std::memset(image.bytes.data()+0x16000,0xcc,p.second.size);
  }
  // Identical uncalled helper prefixes do not compete with an actual CALL
  // target. A changed target still has to satisfy its complete linkage proof.
  for (const auto& p:{kOggCtor0.pattern(),kCrtFormatter0.pattern()}) {
    std::memcpy(image.bytes.data()+0x16000,p.bytes,p.size);
    Check(image.Resolve(&out));
    std::memset(image.bytes.data()+0x16000,0xcc,p.size);
  }
  for (uintptr_t at:{uintptr_t(0x18000),uintptr_t(0x18100),uintptr_t(0x18200)}) {
    image.bytes[at]^=1; image.Reject(); image.bytes[at]^=1;
  }
  image.Absolute(0x18404,image.ogg+1); image.Reject(); image.Absolute(0x18404,image.ogg);
  image.Absolute(image.ctor+0x42,image.ogg); image.Reject(); image.Absolute(image.ctor+0x42,0x18400);
  image.view.sections[1].characteristics|=IMAGE_SCN_MEM_EXECUTE; image.Reject();
  image.view.sections[1].characteristics=IMAGE_SCN_MEM_READ;
  image.view.sections[0].characteristics=IMAGE_SCN_MEM_READ; image.Reject();
  image.view.sections[0].characteristics|=IMAGE_SCN_MEM_EXECUTE;
  image.view.machine=IMAGE_FILE_MACHINE_AMD64; image.Reject();
  image.view.machine=IMAGE_FILE_MACHINE_I386; image.view.pointer_bits=64; image.Reject();
  image.view.pointer_bits=32;
  const size_t original_size=image.view.size;
  image.view.size=image.resource+600; image.Reject(); image.view.size=original_size;
  Check(!ResolveSiglusLegacyResourceMappingProfile(image.view,image.voice+1,&out));
  Check(!ResolveSiglusLegacyResourceMappingProfile(image.view,0,&out));
  Check(!ResolveSiglusLegacyResourceMappingProfile(image.view,image.voice,nullptr));
  // Modern frame-based prologue and 24-byte TextUnion are not this ABI.
  image.bytes[image.resource]=0x55; image.Reject(); image.bytes[image.resource]=0x6a;
  image.bytes[image.ogg+0x23]=0x14; image.Reject();
  image.bytes[image.ogg+0x23]=kOggOpen0.bytes[0x23];
  Check(image.Resolve(&out));
}
struct Memory {
  std::vector<uint8_t> bytes=std::vector<uint8_t>(0x10000,0);
  size_t reads=0;
  bool operator()(uint32_t at,void* out,size_t count) {
    ++reads;
    if (at>=bytes.size() || count>bytes.size()-at) return false;
    std::memcpy(out,bytes.data()+at,count); return true;
  }
  void Word(uint32_t at,uint32_t value) { std::memcpy(bytes.data()+at,&value,4); }
};
struct Source {
  Memory memory;
  SiglusLegacyVoiceSourceLayout layout{0x1234988,0x12300bb,0x1258400};
  SiglusLegacyVoiceSourceCall call{0x5000,0x2000,0x1234,0x4567};
  Source() {
    memory.Word(0x2000,layout.payload_return);
    memory.Word(0x2130,layout.resource_return);
    memory.Word(0x2134,12300045); memory.Word(0x2020,12300045);
    memory.Word(0x2048,45); memory.Word(0x2040,call.reader);
    memory.Word(call.reader,layout.ogg_vtable);
    memory.Word(0x2004,0x20c8); memory.Word(0x2008,call.original_edi);
    memory.Word(0x200c,call.original_ebp);
    Path(L"C:\\audio\\z0123.ovk");
  }
  void Path(const std::wstring& path,bool use_inline=false) {
    memory.Word(0x20c8,0x7770); // Iterator proxy, not the buffer.
    memory.Word(0x20cc,0x6000);
    memory.Word(0x20dc,static_cast<uint32_t>(path.size()));
    memory.Word(0x20e0,use_inline?7:static_cast<uint32_t>(path.size()));
    std::memcpy(memory.bytes.data()+(use_inline?0x20cc:0x6000),path.c_str(),(path.size()+1)*2);
  }
  bool Capture(SiglusVoiceSourceTask* out) {
    return CaptureSiglusLegacyVoiceSource(layout,call,memory,out);
  }
  void Reject() {
    SiglusVoiceSourceTask out; out.key=1; out.path[0]=L'x';
    Check(!Capture(&out)); Check(out.key==0 && out.path[0]==0);
  }
};
void TestCapture() {
  Source first; SiglusVoiceSourceTask out;
  Check(first.Capture(&out));
  Check(out.key==12300045 && out.offset==0x1234 && out.length==0x4567 &&
        std::wstring(out.path)==L"C:\\audio\\z0123.ovk");
  const size_t reads=first.memory.reads;
  Check(reads==24);
  for (const auto& path:{std::wstring(L"C:\\x"),std::wstring(L"\\\\srv\\share\\z.ovk")}) {
    Source f; f.Path(path,path.size()<8); Check(f.Capture(&out));
  }
  { Source f; f.Path(L"C:\\x",true); f.memory.Word(0x20e0,4); f.Reject(); }
  for (uint32_t at:{0x2000u,0x2130u,0x2134u,0x2020u,0x2048u,0x2040u,
                    0x5000u,0x2004u,0x2008u,0x200cu}) {
    Source f; f.memory.bytes[at]^=1; f.Reject();
  }
  for (const auto& path:{L"z.ovk",L"C:z.ovk",L"\\z.ovk",L"\\\\?\\C:\\z.ovk",L"C:\\audio\\"}) {
    Source f; f.Path(path); f.Reject();
  }
  for (size_t fail=1;fail<=reads;++fail) {
    Source f; size_t count=0;
    auto partial=[&](uint32_t a,void* p,size_t n) {
      if (++count==fail) { if (n>1) f.memory(a,p,n-1); return false; }
      return f.memory(a,p,n);
    };
    out.key=77;
    Check(!CaptureSiglusLegacyVoiceSource(f.layout,f.call,partial,&out)); Check(out.key==0);
  }
  // Stable union but changing heap content, or a changed source frame after
  // the first path read, cannot publish an old/new metadata mixture.
  for (uint32_t change:{0x6004u,0x2134u,0x2020u,0x2048u,0x2040u,0x5000u,
                       0x2000u,0x2130u,0x2004u,0x2008u,0x200cu,0x20dcu}) {
    Source f; bool mutated=false;
    auto moving=[&](uint32_t a,void* p,size_t n) {
      const bool ok=f.memory(a,p,n);
      if (a==0x6000 && !mutated) { f.memory.bytes[change]^=1; mutated=true; }
      return ok;
    };
    Check(!CaptureSiglusLegacyVoiceSource(f.layout,f.call,moving,&out));
  }
  {
    Source f; bool mutated=false;
    auto coherent_new_key=[&](uint32_t a,void* p,size_t n) {
      const bool ok=f.memory(a,p,n);
      if (a==0x6000 && !mutated) {
        // Same member in another archive: both reads separately pass all
        // aliases, but the callback must reject a mixed occurrence snapshot.
        f.memory.Word(0x2134,12400045); f.memory.Word(0x2020,12400045);
        mutated=true;
      }
      return ok;
    };
    Check(!CaptureSiglusLegacyVoiceSource(f.layout,f.call,coherent_new_key,&out));
  }
  { Source f; f.call.entry_esp=UINT32_MAX-0x100; f.Reject(); }
  { Source f; f.call.entry_esp++; f.Reject(); }
  { Source f; f.call.reader++; f.Reject(); }
  { Source f; f.layout.payload_return=0; f.Reject(); }
  { Source f; f.layout.resource_return=0; f.Reject(); }
  { Source f; f.layout.ogg_vtable=0; f.Reject(); }
  { Source f; f.memory.Word(0x2134,UINT32_MAX); f.memory.Word(0x2020,UINT32_MAX); f.Reject(); }
  { Source f; f.call.original_edi=UINT32_MAX-8; f.memory.Word(0x2008,f.call.original_edi); f.Reject(); }
  { Source f; f.call.original_edi=0; f.memory.Word(0x2008,0); f.Reject(); }
  { Source f; f.call.original_ebp=0; f.memory.Word(0x200c,0); f.Reject(); }
  { Source f; f.memory.Word(0x20cc,UINT32_MAX-2); f.Reject(); }
  { Source f; f.memory.Word(0x20e0,1); f.Reject(); }
  { Source f; f.memory.Word(0x20dc,520); f.memory.Word(0x20e0,520); f.Reject(); }
  { Source f; f.memory.Word(0x20dc,0); f.Reject(); }
  { Source f; f.memory.Word(0x20e0,UINT32_MAX); f.Reject(); }
  { Source f; f.memory.bytes[0x6006]=0; f.memory.bytes[0x6007]=0; f.Reject(); }
  { Source f; f.memory.bytes[0x6000+std::wstring(L"C:\\audio\\z0123.ovk").size()*2]='x'; f.Reject(); }
  // A 24-byte modern union must not be interpreted as legacy proxy+union.
  { Source f; f.memory.Word(0x20c8,0x6000); f.memory.Word(0x20d8,18); f.memory.Word(0x20dc,31); f.memory.Word(0x20e0,0); f.Reject(); }
  Check(!CaptureSiglusLegacyVoiceSource(first.layout,first.call,first.memory,nullptr));
}
} // namespace
int main() {
  TestResolver(); TestCapture();
  std::printf("PASS Siglus legacy resource %d checks\n",checks);
}
