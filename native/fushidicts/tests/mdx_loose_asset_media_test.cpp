// MDX 的松散兄弟资源（图片 / 图标字体）也必须进 media store（BUG-2147）。
//
// 导入侧此前只收两种兄弟文件：<link href="*.css"> 和 <script src="*.js">。一本把
// 资源散放在 .mdx 旁边、**根本没有 .mdd** 的词典因此丢掉全部图片和字体 ——
// 「剑桥在线2023_发音词典」正是这个形状：条目用 <img src="sound.png"> 当发音按钮、
// 样式表用 @font-face{src:url(cdoicons.woff)} 当图标字体，两个文件都在 .mdx 旁边。
// 弹窗会把 src="sound.png" 重写成 image://?dictionary=…&path=sound.png，而
// getMediaFile 返回空 -> 404 -> 破图塌成 0×0 -> **那个喇叭按钮根本点不着**。
// （条目里的 <audio> 和它的 https 远程 mp3 一直是好的，只是没有任何东西够得着它。）
//
// Guard：条目 <img src> 与样式表 url() 点名的兄弟文件都按裸名进 media store，
// url() 里的 ?query 被剥掉，绝对 URL / 上级路径一律不收，没人引用的文件不被扫进来。
//
// Red/green：把 import_mdx 里 extract_img_src_names / extract_css_url_names 两路
// 摘掉，sound.png / cdoicons.woff 立刻从 store 里消失。
//
// Usage: mdx_loose_asset_media_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "mdx_fixture.hpp"
#include "zip_fixture.hpp"

namespace {
int g_fail = 0;
void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

void write_bytes(const std::string& path, const std::vector<uint8_t>& b) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(reinterpret_cast<const char*>(b.data()), static_cast<std::streamsize>(b.size()));
}

void write_text(const std::string& path, const std::string& t) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(t.data(), static_cast<std::streamsize>(t.size()));
}

std::string media_str(DictionaryQuery& q, const std::string& dict, const char* path) {
  std::vector<char> b = q.get_media_file(dict, path);
  return std::string(b.begin(), b.end());
}
}  // namespace

int main() {
  const std::string base = fushi_test::temp_dir() + "/fushi_mdx_loose_asset";
  std::filesystem::remove_all(std::filesystem::u8path(base));
  std::filesystem::create_directories(std::filesystem::u8path(base));

  const std::string mdx_path = base + "/CamPron.mdx";
  const std::string out_dir = base + "/out";

  // 二进制载荷（PNG 头 / WOFF 头）：读取必须是二进制安全的，不能被当文本截断。
  const std::string sound_png("\x89PNG\r\n\x1a\n\x00\x01\x02\x03 sound", 18);
  const std::string icons_woff("wOFF\x00\x01\x00\x00 icons", 14);
  const std::string sprite_gif("GIF89a sprite bytes", 19);
  const std::string dict_js = "var aud = document.querySelectorAll('.c_aud');\n";
  const std::string unused_png("\x89PNG never referenced", 21);

  // 样式表：@font-face 的裸名 url()、带 ?version 查询串的 url()、以及两种必须被
  // 拒绝的形态（绝对路径 / 远程 URL）。
  const std::string css =
      "@font-face{font-family:'ico-c';src:url(cdoicons.woff) format('woff')}\n"
      ".sp{background:url(\"sprite.gif?version=5.0.287\")}\n"
      ".abs{background:url(/external/images/cdo-sprite.png?version=5.0.287)}\n"
      ".remote{background:url('https://dictionary.cambridge.org/x.png')}\n";
  write_text(base + "/CamPron.css", css);
  write_text(base + "/cdoicons.woff", icons_woff);
  write_text(base + "/sprite.gif", sprite_gif);
  write_text(base + "/sound.png", sound_png);
  write_text(base + "/CamPron.js", dict_js);
  write_text(base + "/never-used.png", unused_png);

  // 条目 HTML 逐字照抄真词典的形状：<link> 样式表、远程 <audio><source>、
  // <img src="sound.png"> 发音按钮、末尾 <script>。
  const std::string definition =
      "<link href=\"CamPron.css\" rel=\"stylesheet\" type=\"text/css\" />"
      "<div class=\"page-content\"><span class=\"hw dhw\">12th man</span>"
      "<audio class=\"hdn\" id=\"audio1\" preload=\"none\">"
      "<source src=\"https://dictionary.cambridge.org//media/english/uk_pron/c/x.mp3\" type=\"audio/mpeg\">"
      "</audio>"
      "<img class=\"i i-volume-up c_aud\" tonclick=\"audio1.play();\" src=\"sound.png\">"
      "<span class=\"ipa dipa\">\xCB\x8Ctwelf\xCE\xB8 \xCB\x88m\xC3\xA6n</span>"
      "</div><script src=\"CamPron.js\"></script>";

  write_bytes(mdx_path, mdx_fixture::build_mdx_plain("CamPron", {{"12th man", definition}}));

  ImportResult r = dictionary_importer::import(mdx_path, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "import failed" : r.errors.front().c_str());
  } else {
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + r.title);

    // 核心：发音按钮的图。
    if (media_str(q, r.title, "sound.png") != sound_png) {
      fail("the <img src> the entries show is not in the media store (the pronunciation "
           "button renders as a broken 0x0 image)");
    }
    // 样式表 url() 点名的字体与雪碧图。
    if (media_str(q, r.title, "cdoicons.woff") != icons_woff) {
      fail("the @font-face url() the stylesheet names is not in the media store");
    }
    if (media_str(q, r.title, "sprite.gif") != sprite_gif) {
      fail("a url() with a ?query suffix must resolve to the bare file name");
    }
    // 既有行为不回归。
    if (media_str(q, r.title, "CamPron.js") != dict_js) {
      fail("the sibling <script src> regressed when loose assets joined the store");
    }
    // 没人引用的文件不被扫进来。
    if (!q.get_media_file(r.title, "never-used.png").empty()) {
      fail("a sibling image the dictionary never references was swept in");
    }
    // 绝对路径 / 远程 URL 的 url() 一律不产生 media key。
    if (!q.get_media_file(r.title, "cdo-sprite.png").empty()) {
      fail("an absolute-path url() must not be resolved against the dictionary directory");
    }
    if (!q.get_media_file(r.title, "x.png").empty()) {
      fail("a remote url() must not be resolved against the dictionary directory");
    }
  }

  std::fprintf(stderr, "mdx_loose_asset_media_test: %s\n", g_fail ? "FAILED" : "PASSED");
  return g_fail ? 1 : 0;
}
