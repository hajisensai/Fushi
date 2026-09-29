// LNReader 插件宿主（fushi/assets/lnreader/lnreader_host.js）的真行为测试：
// 真加载入库的 cheerio/dayjs bundle 与宿主脚本，用一个 tsc 产物形态的插件验证
// require 表、fetch 过桥规整、默认筛选值、存储持久化与章节 XHTML 规整。
// Dart 侧契约见 fushi/lib/src/media/novel/online/lnreader_runtime.dart。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const here = path.dirname(fileURLToPath(import.meta.url));
const assets = path.join(here, '..', '..', 'fushi', 'assets', 'lnreader');

function createHost(routes) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>');
  const requests = [];
  const persisted = [];
  const ctx = vm.createContext({
    console, URL, URLSearchParams, FormData, Blob, Headers, Request, Response,
    TextDecoder, TextEncoder, atob, btoa, setTimeout, clearTimeout,
    DOMParser: dom.window.DOMParser,
    XMLSerializer: dom.window.XMLSerializer,
  });
  ctx.globalThis = ctx;
  ctx.__fushiLnReaderBridge = {
    async fetch(request) {
      requests.push(request);
      const route = routes[request.url];
      if (!route) return { error: 'no route' };
      const body = Buffer.from(route.body ?? '', route.encoding ?? 'utf8');
      return {
        status: route.status ?? 200,
        url: route.finalUrl ?? request.url,
        headers: route.headers ?? { 'content-type': 'text/html' },
        body: body.toString('base64'),
      };
    },
    persistStorage(id, data) {
      persisted.push({ id, data: JSON.parse(JSON.stringify(data)) });
      return Promise.resolve(true);
    },
  };
  vm.runInContext(fs.readFileSync(path.join(assets, 'lnreader_libs.js'), 'utf8'), ctx);
  vm.runInContext(fs.readFileSync(path.join(assets, 'lnreader_host.js'), 'utf8'), ctx);
  return { ln: ctx.__fushiLnReader, requests, persisted };
}

// tsc(ES5, CommonJS) 产物的形态：顶层 require、exports.default = new Plugin()。
const PLUGIN = `
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
var cheerio_1 = require("cheerio");
var fetch_1 = require("@libs/fetch");
var filterInputs_1 = require("@libs/filterInputs");
var novelStatus_1 = require("@libs/novelStatus");
var storage_1 = require("@libs/storage");
var dayjs = require("dayjs");
var TestPlugin = (function () {
  function TestPlugin() {
    this.id = "test.plugin";
    this.name = "Test";
    this.site = "https://novel.example/";
    this.version = "1.0.0";
    this.imageRequestInit = { headers: { Referer: "https://novel.example/" } };
    this.filters = {
      genre: { type: filterInputs_1.FilterTypes.Picker, label: "Genre", value: "all",
        options: [{ label: "All", value: "all" }, { label: "SF", value: "sf" }] },
    };
  }
  TestPlugin.prototype.popularNovels = async function (page, options) {
    var url = this.site + "rank?genre=" + options.filters.genre.value + "&p=" + page
      + (options.showLatestNovels ? "&latest=1" : "");
    var $ = (0, cheerio_1.load)(await (await (0, fetch_1.fetchApi)(url)).text());
    return $(".novel a").map(function (_, a) {
      return { name: $(a).text(), path: $(a).attr("href"), cover: $(a).attr("data-cover") };
    }).get();
  };
  TestPlugin.prototype.searchNovels = async function (term, page) {
    var form = new FormData();
    form.append("q", term);
    var res = await (0, fetch_1.fetchApi)(this.site + "search", {
      method: "POST", body: form, headers: new Headers({ "X-Requested-With": "XMLHttpRequest" }) });
    return (await res.json()).map(function (n) { return { name: n.t, path: n.p }; });
  };
  TestPlugin.prototype.parseNovel = async function (path) {
    storage_1.storage.set("lastNovel", path);
    return { path: path, name: "Book", status: novelStatus_1.NovelStatus.Ongoing,
      chapters: [{ name: "One", path: path + "1", releaseTime: dayjs("2024-01-02").format("YYYY-MM-DD") }],
      totalPages: 3 };
  };
  TestPlugin.prototype.parseChapter = async function (path) {
    return (0, fetch_1.fetchText)(this.site + path.replace(/^\\//, ""), undefined, "shift_jis");
  };
  return TestPlugin;
}());
exports.default = new TestPlugin();
`;

test('装载 tsc 形态插件，describe 报出筛选与封面请求头', () => {
  const { ln } = createHost({});
  const info = ln.load('test.plugin', PLUGIN, {});
  assert.equal(info.name, 'Test');
  assert.equal(info.filters.genre.value, 'all');
  assert.equal(info.imageHeaders.referer, 'https://novel.example/');
  assert.equal(info.hasParsePage, false);
});

test('未知模块报清楚的错；不是插件的代码被拒', () => {
  const { ln } = createHost({});
  assert.throws(() => ln.load('x', 'require("left-pad");', {}), /Module not available.*left-pad/);
  assert.throws(() => ln.load('y', 'exports.default = {};', {}), /Not an LNReader plugin/);
});

test('热门：没传筛选时补插件默认值（真 Syosetu 插件不补就 TypeError）', async () => {
  const { ln, requests } = createHost({
    'https://novel.example/rank?genre=all&p=1': {
      body: '<div class="novel"><a href="/n/1" data-cover="https://img/1.jpg">一</a></div>',
    },
    'https://novel.example/rank?genre=sf&p=2&latest=1': {
      body: '<div class="novel"><a href="/n/2">二</a></div>',
    },
  });
  ln.load('test.plugin', PLUGIN, {});
  const items = await ln.popular('test.plugin', 1, false, null);
  assert.deepEqual(JSON.parse(JSON.stringify(items)), [
    { name: '一', path: '/n/1', cover: 'https://img/1.jpg' },
  ]);
  const latest = await ln.popular('test.plugin', 2, true, { genre: { type: 'Picker', value: 'sf' } });
  assert.equal(latest[0].cover, null);
  assert.equal(requests.length, 2);
});

test('封面：相对 / 协议相对地址按插件站点补全，绝对与 data: 原样', async () => {
  const { ln } = createHost({
    'https://novel.example/rank?genre=all&p=1': {
      body: '<div class="novel">'
        + '<a href="/n/1" data-cover="/img/1.jpg">一</a>'
        + '<a href="/n/2" data-cover="//cdn.example/2.png">二</a>'
        + '<a href="/n/3" data-cover="https://img.example/3.webp">三</a>'
        + '<a href="/n/4" data-cover="data:image/png;base64,AAAA">四</a>'
        + '</div>',
    },
  });
  ln.load('test.plugin', PLUGIN, {});
  const items = JSON.parse(JSON.stringify(await ln.popular('test.plugin', 1, false, null)));
  const covers = items.map((item) => item.cover);
  assert.deepEqual(covers, [
    'https://novel.example/img/1.jpg',
    'https://cdn.example/2.png',
    'https://img.example/3.webp',
    'data:image/png;base64,AAAA',
  ]);
});

test('fetch 过桥：FormData 规整成 multipart 字节 + Content-Type，Headers 摊平', async () => {
  const { ln, requests } = createHost({
    'https://novel.example/search': { body: '[{"t":"検索","p":"/s/1"}]', headers: { 'content-type': 'application/json' } },
  });
  ln.load('test.plugin', PLUGIN, {});
  const found = await ln.search('test.plugin', '異世界', 1);
  assert.equal(found[0].name, '検索');
  const request = requests[0];
  assert.equal(request.method, 'POST');
  assert.equal(request.headers['x-requested-with'], 'XMLHttpRequest');
  assert.match(request.headers['content-type'], /^multipart\/form-data; boundary=/);
  const body = Buffer.from(request.body, 'base64').toString('utf8');
  assert.match(body, /name="q"\r\n\r\n異世界\r\n/);
});

test('fetchText 按插件给的编码解码（Shift_JIS 站）', async () => {
  const { ln } = createHost({
    // 「日本」的 Shift_JIS 字节
    'https://novel.example/c/1': { body: '93fa967b', encoding: 'hex' },
  });
  ln.load('test.plugin', PLUGIN, {});
  assert.equal(await ln.chapter('test.plugin', '/c/1'), '日本');
});

test('fetchText 在非 2xx / 网络失败时回空串（与上游契约一致）', async () => {
  const { ln } = createHost({ 'https://novel.example/c/404': { status: 404, body: 'nope' } });
  ln.load('test.plugin', PLUGIN, {});
  assert.equal(await ln.chapter('test.plugin', '/c/404'), '');
  assert.equal(await ln.chapter('test.plugin', '/c/missing'), '');
});

test('详情：状态 / 章节规整，@libs/storage 写入即落 Dart，重载时带回', async () => {
  const { ln, persisted } = createHost({});
  ln.load('test.plugin', PLUGIN, { old: { created: 1, value: 'kept' } });
  const novel = await ln.novel('test.plugin', '/n/1');
  assert.equal(novel.status, 'Ongoing');
  assert.equal(novel.totalPages, 3);
  assert.deepEqual(JSON.parse(JSON.stringify(novel.chapters)), [
    { name: 'One', path: '/n/11', chapterNumber: null, releaseTime: '2024-01-02', page: null },
  ]);
  assert.equal(persisted.length, 1);
  assert.equal(persisted[0].data.lastNovel.value, '/n/1');
  assert.equal(persisted[0].data.old.value, 'kept');
});

test('resolveUrl：插件没有就 site + path，绝对地址原样', () => {
  const { ln } = createHost({});
  ln.load('test.plugin', PLUGIN, {});
  assert.equal(ln.resolveUrl('test.plugin', '/n/1', true), 'https://novel.example/n/1');
  assert.equal(ln.resolveUrl('test.plugin', 'https://x.example/a', false), 'https://x.example/a');
});

test('章节 → XHTML：去脚本 / 事件 / 链接，图片改名并回报原地址，输出良构', () => {
  const { ln } = createHost({});
  const result = ln.toXhtml(
    '<h1 class="t" onclick="x()">第一話</h1><script>alert(1)</script>'
      + '<p style="color:red">本文<br>改行<a href="https://evil">link</a></p>'
      + '<img src="/img/a.png"><img data-src="https://cdn.example/b.jpg?x=1"><img src="data:image/png;base64,AAAA">'
      + '<ruby>漢字<rt>かんじ</rt></ruby>&nbsp;&amp;',
    'https://novel.example/n/1/',
    'images/c1-',
  );
  assert.doesNotMatch(result.xhtml, /script|onclick|style=|class=|href=/);
  assert.match(result.xhtml, /<br \/>/);
  assert.match(result.xhtml, /<ruby>漢字<rt>かんじ<\/rt><\/ruby>/);
  assert.match(result.xhtml, /<img src="images\/c1-0.png" alt="" \/>/);
  assert.deepEqual(JSON.parse(JSON.stringify(result.images)), [
    { url: 'https://novel.example/img/a.png', fileName: 'images/c1-0.png' },
    { url: 'https://cdn.example/b.jpg?x=1', fileName: 'images/c1-1.jpg' },
  ]);
  assert.doesNotMatch(result.xhtml, /data:image/, 'data: 图片不下载也不留断链');
  const parsed = new JSDOM('').window.DOMParser;
  const doc = new parsed().parseFromString(
    `<html xmlns="http://www.w3.org/1999/xhtml"><body>${result.xhtml}</body></html>`,
    'application/xhtml+xml',
  );
  assert.equal(doc.getElementsByTagName('parsererror').length, 0, 'XHTML 必须良构');
});

// 官方 kakuyomu 插件 1.0.0 的形态：热门读已不存在的旧排行榜 DOM（恒空），其余不动。
function kakuyomuPlugin(version) {
  return `
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
var fetch_1 = require("@libs/fetch");
var cheerio_1 = require("cheerio");
var KakuyomuPlugin = (function () {
  function KakuyomuPlugin() {
    this.id = "kakuyomu"; this.name = "kakuyomu"; this.site = "https://kakuyomu.jp";
    this.version = "${version}";
    this.filters = {
      genre: { type: "Picker", label: "Genre", value: "all", options: [] },
      period: { type: "Picker", label: "Period", value: "entire", options: [] },
    };
  }
  KakuyomuPlugin.prototype.popularNovels = async function () {
    var $ = (0, cheerio_1.load)(await (0, fetch_1.fetchText)(this.site + "/rankings/all/entire"));
    return $(".widget-media-genresWorkList-right > .widget-work").map(function () { return {}; }).get();
  };
  KakuyomuPlugin.prototype.searchNovels = async function () { return []; };
  KakuyomuPlugin.prototype.parseNovel = async function (path) { return { path: path, name: "" }; };
  KakuyomuPlugin.prototype.parseChapter = async function () { return ""; };
  return KakuyomuPlugin;
}());
exports.default = new KakuyomuPlugin();
`;
}

// 2026-09 真站排行榜页的形态：Next.js，排名在内嵌 Apollo 缓存的 rankedWorks 里。
function kakuyomuRankingPage(query, ids) {
  const state = {
    ROOT_QUERY: {
      __typename: 'Query',
      [`rankedWorks(${JSON.stringify(query)})`]: {
        __typename: 'WorkConnection',
        nodes: ids.map((id) => ({ __ref: `Work:${id}` })),
      },
    },
  };
  for (const id of ids) {
    state[`Work:${id}`] = { __typename: 'Work', id, title: `作品${id}`, author: { __ref: 'UserAccount:1' } };
  }
  state[`Work:${ids[0]}`].adminCoverImageUrl = 'https://cdn.kakuyomu.jp/cover.jpg';
  const data = JSON.stringify({ props: { pageProps: { __APOLLO_STATE__: state } } });
  return '<!doctype html><div class="RankingWorkBox_workCard__8UBvb"></div>'
    + `<script id="__NEXT_DATA__" type="application/json">${data}</script>`;
}

test('kakuyomu 1.0.0：热门改读排行榜页内嵌的 rankedWorks（顺序 / 筛选 / 翻页）', async () => {
  const { ln, requests } = createHost({
    'https://kakuyomu.jp/rankings/all/entire?work_variation=long': {
      body: kakuyomuRankingPage({ first: 100, genre: null, period: 'ENTIRE', workVariation: 'LONG' }, ['30', '10', '20']),
    },
    'https://kakuyomu.jp/rankings/fantasy/daily?work_variation=long&page=2': {
      body: kakuyomuRankingPage({ after: 'OTk', first: 100, genre: 'FANTASY', period: 'DAILY', workVariation: 'LONG' }, ['40']),
    },
  });
  ln.load('kakuyomu', kakuyomuPlugin('1.0.0'), {});
  const items = JSON.parse(JSON.stringify(await ln.popular('kakuyomu', 1, false, null)));
  assert.deepEqual(items.map((item) => item.path), ['/works/30', '/works/10', '/works/20']);
  assert.equal(items[0].name, '作品30');
  assert.equal(items[0].cover, 'https://cdn.kakuyomu.jp/cover.jpg');
  assert.match(items[1].cover, /coverNotAvailable/);
  const page2 = await ln.popular('kakuyomu', 2, false, {
    genre: { type: 'Picker', value: 'fantasy' },
    period: { type: 'Picker', value: 'daily' },
  });
  assert.equal(page2[0].path, '/works/40');
  assert.equal(requests.length, 2);
});

test('kakuyomu 补丁在上游发新版后自动退役', async () => {
  const { ln, requests } = createHost({});
  ln.load('kakuyomu', kakuyomuPlugin('1.0.1'), {});
  assert.deepEqual(JSON.parse(JSON.stringify(await ln.popular('kakuyomu', 1, false, null))), []);
  assert.equal(requests[0].url, 'https://kakuyomu.jp/rankings/all/entire', '走的是插件自己的实现');
});

test('插件裸调 fetch 也走宿主桥（LNReader app 里全局 fetch 是无 CORS 的原生网络）', async () => {
  const { ln, requests } = createHost({
    'https://bare.example/api': { body: '[{"n":"裸","p":"/b/1"}]', headers: { 'content-type': 'application/json' } },
  });
  ln.load('bare', `
exports.default = {
  id: "bare", name: "Bare", site: "https://bare.example/", version: "1.0.0",
  popularNovels: async function () {
    var res = await fetch("https://bare.example/api", { headers: { Referer: "https://bare.example/" } });
    return (await res.json()).map(function (x) { return { name: x.n, path: x.p }; });
  },
  searchNovels: async function () { return []; },
  parseNovel: async function (path) { return { path: path }; },
  parseChapter: async function () { return ""; },
};`, {});
  const items = await ln.popular('bare', 1, false, null);
  assert.equal(items[0].name, '裸');
  assert.equal(requests[0].headers.referer, 'https://bare.example/');
});

test('每个请求标上发起插件；国际化域名转 punycode 再过桥', async () => {
  const { ln, requests } = createHost({
    'https://xn--80ac9aeh6f.xn--p1ai/books': { body: '[]', headers: { 'content-type': 'application/json' } },
  });
  ln.load('rnrf', `
var fetch_1 = require("@libs/fetch");
exports.default = {
  id: "rnrf", name: "RNRF", site: "https://ранобэ.рф/", version: "1.0.0",
  popularNovels: async function () { return (await (0, fetch_1.fetchApi)("https://ранобэ.рф/books")).json(); },
  searchNovels: async function () { return []; },
  parseNovel: async function (path) { return { path: path }; },
  parseChapter: async function () { return ""; },
};`, {});
  assert.deepEqual(JSON.parse(JSON.stringify(await ln.popular('rnrf', 1, false, null))), []);
  assert.equal(requests[0].url, 'https://xn--80ac9aeh6f.xn--p1ai/books');
  assert.equal(requests[0].plugin, 'rnrf');
});

test('fetchProto：gRPC-web 帧（1 字节标志 + 4 字节大端长度）编码请求、解码响应', async () => {
  const proto = `syntax = "proto3";
message Req { string slug = 1; }
message Res { string title = 1; int32 count = 2; }`;
  const response = Buffer.concat([
    Buffer.from([0, 0, 0, 0, 9]),
    // Res{title:"Novel", count:3}
    Buffer.from([0x0a, 0x05, 0x4e, 0x6f, 0x76, 0x65, 0x6c, 0x10, 0x03]),
    // 尾随 trailer 帧不应干扰第一帧
    Buffer.from([0x80, 0, 0, 0, 2, 0x61, 0x62]),
  ]);
  const { ln, requests } = createHost({
    'https://grpc.example/api/Get': {
      body: response.toString('hex'),
      encoding: 'hex',
      headers: { 'content-type': 'application/grpc-web+proto' },
    },
  });
  ln.load('proto', `
var fetch_1 = require("@libs/fetch");
var PROTO = ${JSON.stringify(proto)};
exports.default = {
  id: "proto", name: "Proto", site: "https://grpc.example/", version: "1.0.0",
  popularNovels: async function () {
    var res = await (0, fetch_1.fetchProto)(
      { proto: PROTO, requestType: "Req", requestData: { slug: "ab" }, responseType: "Res" },
      "https://grpc.example/api/Get",
      { headers: { "content-type": "application/grpc-web+proto" } });
    return [{ name: res.title + "#" + res.count, path: "/n" }];
  },
  searchNovels: async function () { return []; },
  parseNovel: async function (path) { return { path: path }; },
  parseChapter: async function () { return ""; },
};`, {});
  const items = await ln.popular('proto', 1, false, null);
  assert.equal(items[0].name, 'Novel#3');
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].headers['content-type'], 'application/grpc-web+proto');
  // Req{slug:"ab"} = 0a 02 61 62，前缀 00 + 长度 4
  assert.equal(Buffer.from(requests[0].body, 'base64').toString('hex'), '00000000040a026162');
});

test('dayjs 带 LNReader app 的全局扩展（madara 系 format("LL") 不再原样吐 "LL"）', () => {
  const { ln } = createHost({});
  ln.load('dates', `
var dayjs = require("dayjs");
exports.default = {
  id: "dates", site: "https://d.example/", version: "1.0.0",
  name: [
    dayjs("2024-03-05").format("LL"),
    dayjs("05/03/2024", "DD/MM/YYYY").format("YYYY-MM-DD"),
    typeof dayjs().fromNow,
    dayjs.duration(90, "minutes").asHours(),
  ].join("|"),
  popularNovels: async function () { return []; },
};`, {});
  assert.equal(ln.describe('dates').name, 'March 5, 2024|2024-03-05|function|1.5');
});

test('@libs/aes 与 @libs/utils：与 LNReader 同一套 AES-GCM（wtrlab 解密章节用）', () => {
  const { ln } = createHost({});
  ln.load('aes', `
var aes_1 = require("@libs/aes");
var utils_1 = require("@libs/utils");
var key = new Uint8Array(32), iv = new Uint8Array(12);
var sealed = aes_1.gcm(key, iv).encrypt(utils_1.utf8ToBytes("本文"));
var opened = utils_1.bytesToUtf8(aes_1.gcm(key, iv).decrypt(sealed));
exports.default = {
  id: "aes", name: opened, site: "https://aes.example/", version: String(sealed.length),
  popularNovels: async function () { return []; },
};`, {});
  const info = ln.describe('aes');
  assert.equal(info.name, '本文');
  assert.equal(info.version, String(6 + 16), '密文 = 明文 6 字节 + 16 字节 tag');
});
