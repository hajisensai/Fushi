#undef NDEBUG
#include <cassert>
#include <cstdio>
#include "siglus_eight_arg_glyph.h"

namespace {
using namespace fushi_voice_hook;
using namespace siglus_eight_arg_glyph;
unsigned checks = 0;
struct Piece { uintptr_t at; exact_lookup::MaskedPattern pattern; };
struct Image {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(nullptr, 0x18000,
      MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  exact_lookup::LoadedPeImage view{};
  uintptr_t g, w, t, m, r, font, writer, transform;
  uintptr_t dispatch = 0xc000, selector = 0xc800, manager = 0xd000;
  std::array<Piece,22> pieces;
  explicit Image(bool moved=false, uintptr_t base=0x400000)
      : g(moved?0x8123:0x1000), w(moved?0x3101:0x2000),
        t(moved?0x6023:0x3000), m(moved?0x2107:0x4000),
        r(moved?0x4121:0x5000), font(moved?0x7109:0x6000),
        writer(moved?0x1153:0x7000), transform(moved?0x5149:0x8000),
        pieces{{{g,kGlyphEntry.pattern()}, {g+kGlyphFontOffset,kGlyphFont.pattern()},
          {g+kGlyphCoordinatesOffset,kGlyphCoordinates.pattern()},
          {g+kGlyphReturnOffset,kGlyphReturn.pattern()}, {w,kWrapper.pattern()},
          {t,kScenarioEntry.pattern()}, {t+kScenarioStringOffset,kScenarioString.pattern()},
          {t+kScenarioFieldsOffset,kScenarioFields.pattern()},
          {t+kScenarioAppendOffset,kScenarioAppend.pattern()},
          {t+kScenarioReturnOffset,kScenarioReturn.pattern()}, {m,kMessage.pattern()},
          {r,kRenderEntry.pattern()}, {r+kRenderFirstOffset,kRenderFirst.pattern()},
          {r+kRenderSecondOffset,kRenderSecond.pattern()}, {font,kFontEntry.pattern()},
          {writer,kCoordinateWriter.pattern()}, {transform,kTransformEntry.pattern()},
          {dispatch,kMessageDispatch.pattern()},{selector,kOwnerSelector.pattern()},
          {manager,kRenderGroup.pattern()},{r+kRenderVisibleOffset,kRenderVisible.pattern()},
          {r+kRenderReturnOffset,kRenderReturn.pattern()}}} {
    assert(bytes); std::memset(bytes,0xcc,0x18000);
    view.base=bytes;view.size=0x18000;view.absolute_base=base;
    view.machine=IMAGE_FILE_MACHINE_I386;view.pointer_bits=32;view.section_count=2;
    view.sections[0]={bytes+0x1000,0xf000,0x1000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    view.sections[1]={bytes+0x10000,0x8000,0x10000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE};
    for(const auto& p:pieces) Put(p.at,p.pattern);
    for(auto at:Calls()) CallTo(at,0x9000);
    CallTo(w+kWrapperGlyphCall,g);CallTo(m+kMessageScenarioCall,t);
    CallTo(r+kRenderFirstOffset+kRenderFirstCall,w);
    CallTo(r+kRenderSecondOffset+kRenderSecondCall,w);
    CallTo(g+kGlyphFontOffset+50,font);
    CallTo(g+kGlyphCoordinatesOffset+105,transform);
    CallTo(g+kGlyphCoordinatesOffset+126,writer);
    CallTo(dispatch+55,selector);CallTo(dispatch+68,m);CallTo(manager+142,r);
    for(auto at:{g+6,t+6,m+6,font+6}) AddressTo(at,0x9000);
    for(auto at:{g+27,t+24,m+21,r+10,font+24}) AddressTo(at,0x10000);
    for(auto at:{g+kGlyphFontOffset+1,g+kGlyphCoordinatesOffset+12,w+65})
      AddressTo(at,0x10004);
    AddressTo(m+90,0x10008);
    AddressTo(selector+2,0x10008);
  }
  ~Image(){VirtualFree(bytes,0,MEM_RELEASE);}
  std::array<uintptr_t,27> Calls() const {return {{w+kWrapperGlyphCall,
      m+kMessageScenarioCall,r+kRenderFirstOffset+kRenderFirstCall,
      r+kRenderSecondOffset+kRenderSecondCall,g+kGlyphFontOffset+50,
      g+kGlyphCoordinatesOffset+105,g+kGlyphCoordinatesOffset+126,
      g+kGlyphCoordinatesOffset+6,t+kScenarioAppendOffset+13,
      t+kScenarioReturnOffset+19,m+106,m+111,m+119,m+128,m+267,
      r+24,r+kRenderFirstOffset+184,font+81,dispatch+16,dispatch+43,
      dispatch+55,dispatch+68,dispatch+86,selector+20,manager+72,manager+142,
      r+kRenderReturnOffset+10}};}
  void Put(uintptr_t at,exact_lookup::MaskedPattern p){std::memcpy(bytes+at,p.bytes,p.size);}
  void WordAt(uintptr_t at,uint32_t v){std::memcpy(bytes+at,&v,4);}
  void CallTo(uintptr_t at,uintptr_t to){bytes[at]=0xe8;WordAt(at+1,static_cast<uint32_t>(to-at-5));}
  void AddressTo(uintptr_t at,uintptr_t to){WordAt(at,static_cast<uint32_t>(view.absolute_base+to));}
  void Check(){SiglusEightArgGlyphSites s;assert(Resolve(view,&s));++checks;
    assert(s.glyph_entry_rva==g&&s.wrapper_entry_rva==w&&s.scenario_entry_rva==t);
    assert(s.message_entry_rva==m&&s.render_entry_rva==r&&s.font_entry_rva==font);
    assert(s.coordinate_writer_rva==writer&&s.transform_entry_rva==transform);
    assert(s.glyph_return_rva==g+0x833&&s.wrapper_glyph_return_rva==w+125);
    assert(s.message_scenario_return_rva==m+239);
    assert(s.render_wrapper_returns[0]==r+kRenderFirstOffset+116);
    assert(s.render_wrapper_returns[1]==r+kRenderSecondOffset+105);
    assert(s.config_slot_rva==0x10004&&s.manager_slot_rva==0x10008);
    assert(s.message_caller_return_rva==dispatch+73&&s.owner_selector_rva==selector);
    assert(s.render_group_entry_rva==manager&&s.group_render_return_rva==manager+147);}
  void Reject(){SiglusEightArgGlyphSites s;s.glyph_entry_rva=42;
    assert(!Resolve(view,&s));assert(s.glyph_entry_rva==0&&s.wrapper_entry_rva==0);
    assert(s.render_wrapper_returns[0]==0&&s.config_slot_rva==0);++checks;}
};
}
int main(){
  Image{}.Check();Image{true,0x240000}.Check();
  // Each independently identified function can move; cross-family half-pairs
  // cannot borrow a role-compatible but unproved caller or callee.
  for(unsigned which=0;which<11;++which){Image x;const uintptr_t entries[]={
      x.g,x.w,x.t,x.m,x.r,x.font,x.writer,x.transform,x.dispatch,x.selector,x.manager};
    const exact_lookup::MaskedPattern ps[]={kGlyphEntry.pattern(),kWrapper.pattern(),
      kScenarioEntry.pattern(),kMessage.pattern(),kRenderEntry.pattern(),kFontEntry.pattern(),
      kCoordinateWriter.pattern(),kTransformEntry.pattern(),kMessageDispatch.pattern(),
      kOwnerSelector.pattern(),kRenderGroup.pattern()};
    x.Put(0xa000,ps[which]);x.Reject();
    x.bytes[entries[which]]=0xe9;x.Reject();}
  // Mutate every structural byte, including both ret 20 exits, string ABI,
  // glyph+4/+8 construction, argument forwarding, strides and branch edges.
  {Image x;for(const auto& p:x.pieces)for(size_t n=0;n<p.pattern.size;++n){
    if(p.pattern.mask[n]==0)continue;
    x.bytes[p.at+n]^=1;x.Reject();x.bytes[p.at+n]^=1;
  }x.Check();}
  {Image x;for(auto at:x.Calls()){const auto saved=Word(x.view,at+1);
    for(auto bad:{uintptr_t(0),uintptr_t(0x10000),uintptr_t(0x20000)}){
      x.CallTo(at,bad);x.Reject();}
    x.WordAt(at+1,saved);
  }x.Check();}
  for(unsigned n=0;n<10;++n){Image x;const uintptr_t related[]={
      x.w+kWrapperGlyphCall,x.m+kMessageScenarioCall,
      x.r+kRenderFirstOffset+kRenderFirstCall,x.r+kRenderSecondOffset+kRenderSecondCall,
      x.g+kGlyphFontOffset+50,x.g+kGlyphCoordinatesOffset+105,
      x.g+kGlyphCoordinatesOffset+126,x.dispatch+55,x.dispatch+68,x.manager+142};
    x.CallTo(related[n],0x9100);x.Reject();}
  for(unsigned n=0;n<22;++n){Image x;switch(n){
    case 0:x.AddressTo(x.w+65,0x1000c);break;
    case 1:x.AddressTo(x.g+kGlyphCoordinatesOffset+12,0x1000c);break;
    case 2:x.AddressTo(x.m+90,0x10004);break;
    case 3:x.AddressTo(x.m+90,0x10000);break;
    case 4:x.AddressTo(x.g+kGlyphFontOffset+1,0x10005);break;
    case 5:x.AddressTo(x.g+27,0x9000);break;
    case 6:x.AddressTo(x.t+24,0x1000c);break;
    case 7:x.AddressTo(x.m+21,0x1000c);break;
    case 8:x.AddressTo(x.r+10,0x1000c);break;
    case 9:x.AddressTo(x.font+24,0x1000c);break;
    case 10:x.AddressTo(x.g+6,0x10000);break;
    case 11:x.view.machine=IMAGE_FILE_MACHINE_AMD64;break;
    case 12:x.view.pointer_bits=64;break;
    case 13:x.view.sections[0].characteristics=IMAGE_SCN_MEM_READ;break;
    case 14:x.view.sections[0].characteristics=IMAGE_SCN_MEM_EXECUTE;break;
    case 15:x.view.sections[1].characteristics|=IMAGE_SCN_MEM_EXECUTE;break;
    case 16:x.view.base=nullptr;break;
    case 17:x.view.size=0;break;
    case 18:x.view.absolute_base=UINT32_MAX;break;
    case 19:x.view.section_count=0;break;
    case 20:x.AddressTo(x.selector+2,0x1000c);break;
    case 21:x.view.section_count=static_cast<uint32_t>(x.view.sections.size()+1);break;
  }x.Reject();}
  // Extra callers are allowed to exist, but never become dialogue return sites.
  {Image x;x.CallTo(0xb000,x.g);x.CallTo(0xb010,x.w);x.CallTo(0xb020,x.t);x.Check();}
  {Image x;x.bytes[x.t]=0xe9;x.Reject();} // Existing external Luna hook is not an original entry.
  {Image x;x.Put(x.g+0x400,kGlyphFont.pattern());x.Reject();}
  {Image x;x.Put(x.g+0x400,kGlyphCoordinates.pattern());x.Reject();}
  {Image x;assert(!Resolve(x.view,nullptr));++checks;}
  std::printf("Siglus eight-argument topology: %u checks passed\n",checks);
}
