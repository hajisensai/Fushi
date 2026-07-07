// TODO-1285 screenshot proof: simulate clip-path-failing engine (clip off) and
// verify the html::before opaque overlay hides the padding-region leak.
import zlib from 'node:zlib';
import { launchChromeDriver, resolveChrome } from './cdp_client.mjs';

function decodePng(buf){
  var p=8,w,h,ct,idat=[];
  while(p<buf.length){var len=buf.readUInt32BE(p);var type=buf.toString('ascii',p+4,p+8);var data=buf.slice(p+8,p+8+len);
    if(type==='IHDR'){w=data.readUInt32BE(0);h=data.readUInt32BE(4);ct=data[9];}
    else if(type==='IDAT'){idat.push(data);} else if(type==='IEND')break; p+=12+len;}
  var raw=zlib.inflateSync(Buffer.concat(idat)); var ch=ct===6?4:(ct===2?3:1); var stride=w*ch;
  var out=Buffer.alloc(h*stride); var pos=0;
  for(var y=0;y<h;y++){var f=raw[pos++];for(var x=0;x<stride;x++){var v=raw[pos++];
    var a=x>=ch?out[y*stride+x-ch]:0; var b=y>0?out[(y-1)*stride+x]:0; var c=(x>=ch&&y>0)?out[(y-1)*stride+x-ch]:0; var r;
    switch(f){case 0:r=v;break;case 1:r=v+a;break;case 2:r=v+b;break;case 3:r=v+((a+b)>>1);break;
      case 4:{var pp=a+b-c,pa=Math.abs(pp-a),pb=Math.abs(pp-b),pc=Math.abs(pp-c);r=v+((pa<=pb&&pa<=pc)?a:(pb<=pc?b:c));break;}default:r=v;}
    out[y*stride+x]=r&0xff;}}
  return {w:w,h:h,ch:ch,data:out};
}
function px(img,x,y){x=Math.round(x);y=Math.round(y);var i=(y*img.w+x)*img.ch;return [img.data[i],img.data[i+1],img.data[i+2]];}
function isText(rgb){return (rgb[0]+rgb[1]+rgb[2])<3*180;}

var G={pw:1000,V:800,ml:70,mr:70,mt:24,mb:44,gap:22,font:22,N:2};
function buildHtml(useClip,useOverlay){
  var base='calc(100vw - '+G.ml+'px - '+G.mr+'px)';
  var subCss='max(1px, calc(('+base+' - '+((G.N-1)*G.gap)+'px) / '+G.N+'))';
  var clip=useClip?'clip-path: inset('+G.mt+'px '+G.mr+'px '+G.mb+'px '+G.ml+'px) !important;':'';
  var overlay=useOverlay?('html::before{content:"";position:fixed;top:0;right:0;bottom:0;left:0;box-sizing:border-box;pointer-events:none;z-index:2147483000;border-style:solid;border-color:#ffffff;border-top-width:'+G.mt+'px;border-right-width:'+G.mr+'px;border-bottom-width:'+G.mb+'px;border-left-width:'+G.ml+'px;}'):'';
  var lots='日本語のテキストです。'.repeat(4000);
  return '<!doctype html><html><head><meta charset="utf-8"><style>'
    +'html,body{margin:0;padding:0;background:#ffffff;color:#000000;}'
    +'html{width:100vw;height:100vh;overflow:hidden;}'
    +'body{width:100vw;height:100vh;box-sizing:border-box;font-size:'+G.font+'px;line-height:1.8;'
    +'column-width:'+subCss+' !important;column-count:'+G.N+' !important;column-fill:auto !important;column-gap:'+G.gap+'px !important;'
    +'padding:'+G.mt+'px '+G.mr+'px '+G.mb+'px '+G.ml+'px !important;overflow:hidden;writing-mode:horizontal-tb;'+clip+'}'
    +overlay+'</style></head><body>'+lots+'</body></html>';
}

async function main(){
  if(!resolveChrome()){console.log('NO_CHROME');process.exit(2);}
  var driver=await launchChromeDriver();
  var scrollExpr='(function(){var el=document.body,cs=getComputedStyle(el);var gap=parseFloat(cs.columnGap)||0;var fb='+G.pw+'-'+G.ml+'-'+G.mr+';el.scrollLeft=Math.round(fb+gap);return el.scrollLeft;})()';
  var cases=[['clip=Y overlay=N  (current code in Blink)',true,false],
             ['clip=N overlay=N  (SIMULATED clip-failing engine)',false,false],
             ['clip=N overlay=Y  (FIX: overlay only, no clip)',false,true],
             ['clip=Y overlay=Y  (fix shipped, Blink)',true,true]];
  try{
    for(var i=0;i<cases.length;i++){
      var label=cases[i][0],useClip=cases[i][1],useOverlay=cases[i][2];
      var b64=await driver.snap(buildHtml(useClip,useOverlay),scrollExpr,G.pw,G.V);
      var img=decodePng(Buffer.from(b64,'base64'));
      var midY=G.V/2, leftHas=false,rightHas=false;
      for(var yy=G.mt+2; yy<G.V-G.mb-2; yy++){
        if(isText(px(img,G.ml*0.5,yy)))leftHas=true;
        if(isText(px(img,G.pw-G.mr*0.5,yy)))rightHas=true;
      }
      var content=px(img,G.ml+(G.pw-G.ml-G.mr)*0.5,midY);
      var contentHasText=false;
      for(var yy2=G.mt+2; yy2<G.V-G.mb-2; yy2++){ if(isText(px(img,200,yy2))||isText(px(img,800,yy2))){contentHasText=true;break;} }
      console.log('['+label+'] img '+img.w+'x'+img.h+' ch'+img.ch
        +' | leftMarginText='+leftHas+' rightMarginText='+rightHas
        +' contentHasText='+contentHasText
        +'  => '+((leftHas||rightHas)?'LEAK':'clean'));
    }
    driver.close();process.exit(0);
  }catch(e){console.log('ERR',e.stack||e.message);try{driver.close();}catch(_){}process.exit(3);}
}
main();
