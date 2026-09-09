#undef NDEBUG
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <vector>
#include "siglus_legacy_message_profile.h"
#include "siglus_legacy_resource.h"
#include "siglus_image.h"

namespace {
using namespace fushi_voice_hook;
exact_lookup::LoadedPeImage opened_image{};
HMODULE expected_module=reinterpret_cast<HMODULE>(0x12340000);
bool open_allowed=true;
unsigned open_calls=0;
int checks=0;
void Check(bool value,const char* boundary) {
  ++checks;
  if(!value){std::fprintf(stderr,"FAIL %s (check %d)\n",boundary,checks);std::exit(91);}
}
}
// The sole production seam: PE mapping is synthetic, but both complete pure
// resolvers and the actual live admission functions below execute unchanged.
namespace fushi_voice_hook {
bool TestOpenSiglusLoadedImage(HMODULE module,exact_lookup::LoadedPeImage* image) {
  ++open_calls;
  if(!open_allowed || module!=expected_module || image==nullptr)return false;
  *image=opened_image;return true;
}
}
#define OpenSiglusLoadedImage TestOpenSiglusLoadedImage
#include "siglus_legacy_live_admission.h"
#undef OpenSiglusLoadedImage
namespace {
LegacyGlyphSites g_siglus_legacy_glyph_sites;

struct Image {
  std::vector<uint8_t> bytes=std::vector<uint8_t>(0x24000,0xcc);
  exact_lookup::LoadedPeImage view{};
  SiglusLookupProfile lane{};
  uintptr_t voice,play,resource,formatter,string_ctor,ctor,ogg,crt,archive,read;
  uintptr_t message,text,helper;
  explicit Image(uintptr_t shift=0,uintptr_t base=0x14000000) {
    using namespace siglus_legacy_resource;
    view.base=bytes.data();view.size=bytes.size();view.absolute_base=base;
    view.machine=IMAGE_FILE_MACHINE_I386;view.pointer_bits=32;view.section_count=3;
    view.sections[0]={bytes.data()+0x1000,0x17000,0x1000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_EXECUTE};
    view.sections[1]={bytes.data()+0x18000,0x8000,0x18000,IMAGE_SCN_MEM_READ};
    view.sections[2]={bytes.data()+0x20000,0x4000,0x20000,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE};
    voice=0x1000+shift;play=0x3000+2*shift;resource=0x5000+3*shift;
    formatter=0x7000+4*shift;string_ctor=0x9000+5*shift;
    ctor=0xb000+6*shift;ogg=0xd000+7*shift;crt=0x10000+8*shift;
    archive=0x12000+9*shift;read=0x14000+10*shift;
    helper=0x15000;message=0x16000+shift;text=0x17000+shift;
    const std::pair<uintptr_t,exact_lookup::MaskedPattern> parts[]={
      {voice,kVoice0.pattern()},{play,kPlay0.pattern()},
      {resource,kResource0.pattern()},{resource+562,kResource1.pattern()},
      {resource+1123,kResource2.pattern()},{resource+1687,kResource3.pattern()},
      {resource+2247,kResource4.pattern()},{resource+2808,kResource5.pattern()},
      {formatter,kFormatter0.pattern()},{string_ctor,kStringCtor0.pattern()},
      {ctor,kOggCtor0.pattern()},{ogg,kOggOpen0.pattern()},
      {crt,kCrtFormatter0.pattern()},{archive,kArchiveOpen0.pattern()},
      {read,kArchiveRead0.pattern()}};
    for(const auto& part:parts)Put(part.first,part.second);
    const std::pair<uintptr_t,uintptr_t> edges[]={
      {voice+0x73,play},{play+0xb6,resource},
      {resource+0x28b,string_ctor},{resource+0x294,formatter},
      {formatter+0x73,crt},{resource+0x710,string_ctor},
      {resource+0x731,archive},{resource+0x7e0,read},
      {resource+0x82d,read},{resource+0x93b,ctor}};
    for(const auto& edge:edges)Call(edge.first,edge.second);
    Literal(resource+0x279,0x18000,L"z%04d.ovk");
    Literal(resource+0x6fd,0x18100,L"rb");Literal(ogg+0x33,0x18200,L"rb");
    Absolute(ctor+0x42,0x18400);Absolute(0x18404,ogg);
    Put(message,siglus_legacy_message::kMessage.pattern());
    for(size_t n:siglus_legacy_message::kMessageGlobals)Absolute(message+n,0x21000);
    for(size_t n:siglus_legacy_message::kVoiceGlobals)Absolute(voice+n,0x21000);
    for(size_t n:siglus_legacy_message::kScriptReferences)Absolute(message+n,0x21200);
    Absolute(voice+21,0x21200);Absolute(voice+121,0x21200);Absolute(message+3,helper);
    for(size_t n:siglus_legacy_message::kMessageCalls)
      Call(message+n,n==siglus_legacy_message::kTextCall?text:helper);
    Call(voice+14,helper);
    bytes[text]=0x6a;bytes[text+1]=0xff;bytes[text+2]=0x68;Absolute(text+3,helper);
    Put(text+7,siglus_legacy_glyph::kTextTail.pattern());
    lane.pe_machine=IMAGE_FILE_MACHINE_I386;lane.pointer_bits=32;
    lane.text_feed=SiglusLookupTextFeed::kLunaScenarioLane;
    lane.glyph_abi=SiglusGlyphLayoutAbi::kStackSixteenArguments;
    lane.exact_text_rva=text;lane.glyph_layout_rva=helper;
    Activate();
  }
  void Put(uintptr_t at,exact_lookup::MaskedPattern p){std::memcpy(bytes.data()+at,p.bytes,p.size);}
  void Word(uintptr_t at,uint32_t value){std::memcpy(bytes.data()+at,&value,4);}
  void Absolute(uintptr_t at,uintptr_t target){Word(at,static_cast<uint32_t>(view.absolute_base+target));}
  void Call(uintptr_t at,uintptr_t target){Check(bytes[at]==0xe8,"fixture direct CALL");Word(at+1,static_cast<uint32_t>(target-at-5));}
  template<size_t N>void Literal(uintptr_t at,uintptr_t target,const wchar_t(&s)[N]){
    Absolute(at,target);std::memcpy(bytes.data()+target,s,sizeof(s));
  }
  void Activate(){opened_image=view;g_siglus_legacy_glyph_sites={};
    g_siglus_legacy_glyph_sites.text_entry_rva=text;g_siglus_legacy_glyph_sites.glyph_entry_rva=helper;}
  void Pure(){SiglusLegacyMessageProfile m;SiglusLegacyResourceMappingProfile r;
    Check(ResolveSiglusLegacyMessageProfile(view,lane,g_siglus_legacy_glyph_sites,&m),"real pure message resolver");
    Check(m.voice_entry_rva==voice,"shared voice entry");
    Check(ResolveSiglusLegacyResourceMappingProfile(view,m.voice_entry_rva,&r),"real pure resource resolver");
    Check(r.ogg_open_rva==ogg&&bytes[ogg]==0x83,"legacy Ogg SUB ESP entry");}
  bool Source(){SiglusLegacyResourceMappingProfile p;
    return ResolveLiveSiglusLegacyVoiceSource(expected_module,voice,&p);}
  bool Message(){SiglusLegacyMessageProfile p;
    return ResolveLiveSiglusLegacyMessage(expected_module,lane,g_siglus_legacy_glyph_sites,&p);}
  void Detour(uintptr_t at){bytes[at]=0xe9;Word(at+1,0x40000000);}
};
}
int main(int argc,char** argv){
  const bool source_only=argc==2&&std::strcmp(argv[1],"--source")==0;
  const bool message_only=argc==2&&std::strcmp(argv[1],"--message")==0;
  for(uintptr_t shift:{uintptr_t(0),uintptr_t(0x25)}){
    Image x(shift);x.Pure();
    if(!message_only)Check(x.Source(),"actual live legacy source admits complete 83 EC 20 ABI");
    if(!source_only)Check(x.Message(),"actual live legacy message admits complete legacy resource ABI");
  }
  if(source_only||message_only)return 0;
  // A valid pure message alone is insufficient: the full resource chain and
  // its unmodified Ogg entry must still pass in the live message wrapper.
  for(int damaged=0;damaged<5;++damaged){Image x;
    switch(damaged){
      case 0:x.Detour(x.ogg);break;
      case 1:x.Detour(x.voice);break;
      case 2:x.bytes[x.resource+0x99]^=1;break;
      case 3:x.Absolute(0x18404,x.ogg+1);break;
      case 4:x.Call(x.voice+0x73,x.play+1);break;
    }
    Check(!x.Source(),"source rejects detour or broken exact resource proof");
    Check(!x.Message(),"message rejects missing independent resource proof");
  }
  {Image x;x.Detour(x.text);
    SiglusLegacyMessageProfile p;
    Check(ResolveSiglusLegacyMessageProfile(x.view,x.lane,g_siglus_legacy_glyph_sites,&p),"pure read-only text detour observation");
    Check(!x.Message(),"live message refuses to own existing Luna detour");}
  {Image x;x.Detour(x.message);Check(!x.Message(),"live message rejects message detour");}
  {Image x;open_allowed=false;const unsigned before=open_calls;
    Check(!x.Source()&&!x.Message(),"failed live PE opener");
    Check(open_calls==before+2,"one opener attempt per wrapper");open_allowed=true;}
  {Image x;x.view.machine=IMAGE_FILE_MACHINE_AMD64;x.Activate();
    Check(!x.Source()&&!x.Message(),"legacy x64 image rejection");}
  std::printf("siglus_legacy_live_admission_test: PASS (%d checks)\n",checks);
}
