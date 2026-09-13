#undef NDEBUG
#include <windows.h>
#include <cassert>
#include <cstdio>
#include "siglus_legacy_message_profile.h"

namespace {
using namespace fushi_voice_hook;
using namespace siglus_legacy_message;
struct Image {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(nullptr, 0xa000,
      MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  exact_lookup::LoadedPeImage view{};
  LegacyGlyphSites sites{};
  SiglusLookupProfile lane{};
  uintptr_t message, voice, text;
  explicit Image(uintptr_t m=0x1000, uintptr_t v=0x2000, uintptr_t t=0x3000,
                 uintptr_t base=0x400000) : message(m), voice(v), text(t) {
    assert(bytes);std::memset(bytes,0xcc,0xa000);
    view.base=bytes;view.absolute_base=base;view.size=0xa000;
    view.machine=IMAGE_FILE_MACHINE_I386;view.pointer_bits=32;view.section_count=2;
    view.sections[0]={bytes+0x1000,0x7000,0x1000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    view.sections[1]={bytes+0x8000,0x2000,0x8000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE};
    sites.text_entry_rva=text;sites.glyph_entry_rva=0x7000;
    lane.pe_machine=IMAGE_FILE_MACHINE_I386;lane.pointer_bits=32;
    lane.text_feed=SiglusLookupTextFeed::kLunaScenarioLane;
    lane.glyph_abi=SiglusGlyphLayoutAbi::kStackSixteenArguments;
    lane.exact_text_rva=text;lane.glyph_layout_rva=sites.glyph_entry_rva;
    Put(message,kMessage.pattern());Put(voice,kVoice.pattern());
    for(size_t n:kMessageGlobals) Address(message+n,0x8000);
    for(size_t n:kVoiceGlobals) Address(voice+n,0x8000);
    for(size_t n:kScriptReferences) Address(message+n,0x8100);
    Address(voice+21,0x8100);Address(voice+121,0x8100);
    Address(message+3,0x6000);
    for(size_t n:kMessageCalls) Call(message+n,n==kTextCall?text:0x6000);
    Call(voice+14,0x6000);Call(voice+115,0x6000);
    bytes[text]=0x6a;bytes[text+1]=0xff;bytes[text+2]=0x68;Address(text+3,0x6000);
    Put(text+7,siglus_legacy_glyph::kTextTail.pattern());
  }
  ~Image(){VirtualFree(bytes,0,MEM_RELEASE);}
  void Put(uintptr_t at,exact_lookup::MaskedPattern p){std::memcpy(bytes+at,p.bytes,p.size);}
  void Word(uintptr_t at,uint32_t value){std::memcpy(bytes+at,&value,4);}
  void Address(uintptr_t at,uintptr_t rva){Word(at,static_cast<uint32_t>(view.absolute_base+rva));}
  void Call(uintptr_t at,uintptr_t rva){bytes[at]=0xe8;Word(at+1,static_cast<uint32_t>(rva-at-5));}
  void Check(){SiglusLegacyMessageProfile p;assert(ResolveSiglusLegacyMessageProfile(view,lane,sites,&p));
    assert(p.message_entry_rva==message&&p.voice_entry_rva==voice&&p.text_entry_rva==text);
    assert(p.text_return_rva==message+kTextCall+5&&p.script_slot_rva==0x8100);
    assert(p.owner_voice_key_offset==0x120&&p.owner_voice_flag_offset==0x124);
    assert(p.script_voice_key_offset==0x19c&&p.script_voice_second_offset==0x1a0&&p.script_voice_flag_offset==0x1a4);}
  void Reject(){SiglusLegacyMessageProfile p;p.message_entry_rva=42;
    assert(!ResolveSiglusLegacyMessageProfile(view,lane,sites,&p));
    assert(p.message_entry_rva==0&&p.script_slot_rva==0);}
};
}
int main(){
  Image{}.Check();Image{0x2123,0x4107,0x5101,0x110000}.Check();
  for(int i=0;i<21;++i){Image x;switch(i){
    case 0:x.Put(0x4000,kMessage.pattern());break;
    case 1:x.Put(0x4000,kVoice.pattern());break;
    case 2:x.Call(x.message+kTextCall,x.text+1);break;
    case 3:x.Call(x.message+148,x.text);break;
    case 4:x.Address(x.voice+121,0x8104);break;
    case 5:x.Address(x.message+256,0x8104);break;
    case 6:x.Address(x.voice+1,0x8004);break;
    case 7:x.Address(x.voice+38,0x8004);break;
    case 8:x.Address(x.message+33,0x8004);break;
    case 9:x.Address(x.message+3,0x8000);break;
    case 10:x.Address(x.message+195,0x1000);break;
    case 11:x.view.machine=IMAGE_FILE_MACHINE_AMD64;break;
    case 12:x.view.pointer_bits=64;break;
    case 13:x.lane.glyph_abi=SiglusGlyphLayoutAbi::kEcxTenArguments;break;
    case 14:x.lane.exact_text_rva++;break;
    case 15:x.lane.glyph_layout_rva++;break;
    case 16:x.view.sections[0].characteristics=IMAGE_SCN_MEM_READ;break;
    case 17:x.view.sections[1].characteristics=IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE|IMAGE_SCN_MEM_EXECUTE;break;
    case 18:x.Call(x.message+584,0x6100);break;
    case 19:x.lane.text_feed=SiglusLookupTextFeed::kNativeEcxTextUnion;break;
    case 20:x.sites.glyph_entry_rva=0;x.lane.glyph_layout_rva=0;break;
  }x.Reject();}
  // Every structural byte, including all branch and stack deltas, is required.
  {Image x;const exact_lookup::MaskedPattern ps[]={kMessage.pattern(),kVoice.pattern()};
    const uintptr_t addresses[]={x.message,x.voice};
    for(size_t p=0;p<2;++p)for(size_t i=0;i<ps[p].size;++i){
      if(!ps[p].mask[i])continue;
      x.bytes[addresses[p]+i]^=1;x.Reject();x.bytes[addresses[p]+i]^=1;
    }x.Check();}
  for(size_t n:kMessageCalls){Image x;x.Call(x.message+n,0x9000);x.Reject();}
  for(size_t n:kMessageGlobals){Image x;x.Address(x.message+n,0x8001);x.Reject();}
  // A legitimate existing Luna external detour is accepted through the already
  // admitted exact body; an internal branch or destroyed body is not.
  {Image x;x.bytes[x.text]=0xe9;x.Word(x.text+1,0x60000000);x.Check();
    x.Word(x.text+1,0x100);x.Reject();}
  {Image x;x.bytes[x.text+7]^=1;x.Reject();}
  {Image x;x.view.base=nullptr;x.Reject();}
  assert(!ResolveSiglusLegacyMessageProfile({}, {}, {}, nullptr));
  std::puts("siglus_legacy_message_profile_test passed");
}
