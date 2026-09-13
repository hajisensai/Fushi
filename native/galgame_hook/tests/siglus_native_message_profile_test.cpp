#undef NDEBUG
#include <windows.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include "siglus_native_message_profile.h"

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_native_message;
struct Layout { uintptr_t outer=0x1000,voice=0x2000,renderer=0x3000,text=0x4000; };
struct Image {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(nullptr,0x9000,
      MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
  exact_lookup::LoadedPeImage view{};
  SiglusLookupProfile lane{};
  Layout at;
  bool compact;
  size_t renderer_call;
  uintptr_t bridge, surface, prefix, write, cleanup, voice_exit;
  explicit Image(Layout where={}, bool use_compact=false)
      : at(where), compact(use_compact), renderer_call(compact ? kCompactRendererCall : kRendererCall) {
    assert(bytes); memset(bytes,0xcc,0x9000);
    view.base=bytes;view.absolute_base=0x400000;view.size=0x9000;
    view.machine=IMAGE_FILE_MACHINE_I386;view.pointer_bits=32;view.section_count=2;
    view.sections[0]={bytes+0x1000,0x7000,0x1000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    view.sections[1]={bytes+0x8000,0x1000,0x8000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE};
    lane.pe_machine=IMAGE_FILE_MACHINE_I386;lane.pointer_bits=32;
    lane.text_feed=SiglusLookupTextFeed::kNativeEcxTextUnion;lane.exact_text_rva=at.text;
    bridge=at.outer+kEntry.bytes.size()+6;surface=bridge+kTextBridge.bytes.size();
    lane.exact_text_return_rva=bridge+kTextCall+5;
    cleanup=at.outer+0x500;prefix=at.voice+kVoiceEntry.bytes.size()+6;
    write=at.voice+0x150;voice_exit=at.voice+0x250;
    Put(at.outer,kEntry.pattern());Branch(at.outer+kEntry.bytes.size(),cleanup);
    Put(bridge,kTextBridge.pattern());Put(surface,compact?kCompactSurface.pattern():kSurface.pattern());Put(cleanup,kCleanup.pattern());
    Put(at.voice,kVoiceEntry.pattern());Branch(at.voice+kVoiceEntry.bytes.size(),voice_exit);
    Put(prefix,kVoicePrefix.pattern());Put(write,kVoiceWrite.pattern());
    Put(voice_exit,siglus_message::kVoiceReturn.pattern());Put(at.renderer,compact?kCompactRendererEntry.pattern():kRendererEntry.pattern());
    bytes[at.text]=0x53;bytes[at.text+1]=0x8b;bytes[at.text+2]=0x1d;WordAt(at.text+3,0x408010);
    Put(at.text+7,siglus_native_family::kTextTail.pattern());
    Put(at.text+0x100,siglus_native_family::kTextCopy.pattern());
    Put(at.text+0x200,siglus_native_family::kTextReturn.pattern());
    WordAt(bridge+kBridgeGlobal,0x408000);WordAt(bridge+kBridgeSecondGlobal,0x408000);
    WordAt(prefix+2,0x408000);
    Call(bridge+kTextCall,at.text);Call(surface+renderer_call,at.renderer);
    Call(bridge+kBridgeFirstPrepareCall,0x6000);Call(prefix+24,0x6000);
    Call(bridge+kBridgeSecondPrepareCall,0x6200);Call(prefix+29,0x6200);
  }
  ~Image(){VirtualFree(bytes,0,MEM_RELEASE);}
  void Put(uintptr_t r,const exact_lookup::MaskedPattern& p){memcpy(bytes+r,p.bytes,p.size);}
  void WordAt(uintptr_t r,uint32_t v){memcpy(bytes+r,&v,4);}
  void Call(uintptr_t r,uintptr_t target){bytes[r]=0xe8;WordAt(r+1,static_cast<uint32_t>(target-r-5));}
  void Branch(uintptr_t r,uintptr_t target){bytes[r]=0x0f;bytes[r+1]=0x84;WordAt(r+2,static_cast<uint32_t>(target-r-6));}
  void Check(){SiglusNativeMessageProfile p;assert(ResolveSiglusNativeMessageProfile(view,lane,&p));
    assert(p.message_entry_rva==at.outer&&p.native_text_return_rva==bridge+kTextCall+5);
    assert(p.voice_entry_rva==at.voice&&p.renderer_entry_rva==at.renderer);
    assert(p.owner_voice_key_offset==0x1f8&&p.owner_surface_index_offset==0x1e0);
    assert(p.owner_surface_begin_offset==0x228&&p.owner_surface_end_offset==0x22c&&p.surface_stride==0x1c0);}
  void Reject(){SiglusNativeMessageProfile p;p.message_entry_rva=123;
    assert(!ResolveSiglusNativeMessageProfile(view,lane,&p));assert(p.message_entry_rva==0&&p.surface_stride==0);}
};
}
int main(){
  for(bool compact:{false,true}) {
  Image{{},compact}.Check();Image{{0x1137,0x2271,0x3083,0x4156},compact}.Check();
  // Every independently required anchor remains globally unique; an extra
  // partial family must not be selected according to proximity or scan order.
  for(int i=0;i<9;++i){Image x({},compact);switch(i){
    case 0:x.Put(0x7000,kEntry.pattern());break;
    case 1:x.Put(0x7000,kTextBridge.pattern());break;
    case 2:x.Put(0x7000,kSurface.pattern());break;
    case 3:x.Put(0x7000,kRendererEntry.pattern());break;
    case 4:x.Put(0x7000,kVoiceEntry.pattern());break;
    case 5:x.Put(0x7000,kVoicePrefix.pattern());break;
    case 6:x.Put(0x7000,kVoiceWrite.pattern());break;
    case 7:x.Put(0x7000,kCompactSurface.pattern());break;
    case 8:x.Put(0x7000,kCompactRendererEntry.pattern());break;
  }x.Reject();}
  for(int i=0;i<19;++i){Image x({},compact);switch(i){
    case 0:x.Call(x.bridge+kTextCall,x.at.text+1);break;
    case 1:x.Call(x.surface+x.renderer_call,x.at.renderer+1);break;
    case 2:x.Call(x.bridge+kBridgeFirstPrepareCall,0x6100);break;
    case 3:x.Call(x.prefix+29,0x6300);break;
    case 4:x.WordAt(x.bridge+kBridgeSecondGlobal,0x408004);break;
    case 5:x.WordAt(x.prefix+2,0x408004);break;
    case 6:x.WordAt(x.bridge+kBridgeGlobal,0x408001);break;
    case 7:x.WordAt(x.at.text+3,0x401000);break;
    case 8:x.Call(x.at.outer+0x400,x.at.text);break;
    case 9:x.Call(x.at.outer+0x400,x.at.renderer);break;
    case 10:x.Branch(x.at.outer+kEntry.bytes.size(),x.at.voice);break;
    case 11:x.Branch(x.at.voice+kVoiceEntry.bytes.size(),0x8fff);break;
    case 12:x.view.machine=IMAGE_FILE_MACHINE_AMD64;break;
    case 13:x.view.pointer_bits=64;break;
    case 14:x.lane.text_feed=SiglusLookupTextFeed::kLunaScenarioLane;break;
    case 15:x.view.sections[0].characteristics=IMAGE_SCN_MEM_READ;break;
    case 16:x.lane.exact_text_rva++;break;
    case 17:x.lane.exact_text_return_rva++;break;
    case 18:x.bytes[x.at.text]=0xe9;break; // Never admit an already detoured entry.
  }x.Reject();}
  // Branch/frame/owner/ABI bytes are never wildcard-expanded by this family.
  {Image x({},compact);const exact_lookup::MaskedPattern patterns[]={kEntry.pattern(),kTextBridge.pattern(),compact?kCompactSurface.pattern():kSurface.pattern(),compact?kCompactRendererEntry.pattern():kRendererEntry.pattern(),kVoiceEntry.pattern(),kVoicePrefix.pattern(),kVoiceWrite.pattern(),kCleanup.pattern()};
   const uintptr_t sites[]={x.at.outer,x.bridge,x.surface,x.at.renderer,x.at.voice,x.prefix,x.write,x.cleanup};
   for(size_t i=0;i<8;++i)for(size_t n=0;n<patterns[i].size;++n){
     if(patterns[i].mask[n]==0)continue;const uint8_t old=x.bytes[sites[i]+n];
     x.bytes[sites[i]+n]^=1;x.Reject();x.bytes[sites[i]+n]=old;
   }x.Check();}
  // Swapping only the callee-local layout creates a cross-family chimera even
  // though the direct call and each independently unique signature still match.
  {Image x({},compact);x.Put(x.at.renderer,compact?kRendererEntry.pattern():kCompactRendererEntry.pattern());x.Reject();}
  {Image x({},compact);x.Put(0x6800,compact?kSurface.pattern():kCompactSurface.pattern());
   x.Put(0x7000,compact?kRendererEntry.pattern():kCompactRendererEntry.pattern());x.Reject();}
  {Image x({},compact);x.view.base=nullptr;x.Reject();}
  }
  std::puts("siglus_native_message_profile_test passed");
}
