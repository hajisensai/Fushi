/*
 * Fushi 的 LNReader 插件宿主（在一个 headless WebView 里运行）。
 *
 * LNReader 插件是 tsc 出的 ES5 CommonJS：`exports.default = new Plugin()`，运行时
 * `require` 一小撮模块（cheerio / htmlparser2 / dayjs 来自同目录的
 * lnreader_libs.js，`@libs/*` 由本文件实现）。浏览器引擎自带 URL / FormData /
 * Headers / TextDecoder(gbk…) / atob，所以这里不补 polyfill——那正是 QuickJS 移植
 * 版反复出问题的地方。
 *
 * 🔴 网络一律经宿主桥（`bridge.fetch`）：WebView 自己的 fetch 受 CORS 约束、改不了
 * Referer / Cookie / User-Agent，也绕过了 app 的代理装配。请求体（FormData /
 * URLSearchParams / 字符串）先经 `new Request()` 规整成字节 + Content-Type 再过桥，
 * Headers 对象摊平成普通对象——JSON 过桥会把它们变成 `{}`（Zangetsu #93 同坑）。
 *
 * Dart 侧契约见 fushi/lib/src/media/novel/online/lnreader_runtime.dart。
 */
(function () {
  'use strict';

  var libs = globalThis.__fushiLnReaderLibs;
  if (!libs) throw new Error('lnreader_libs.js must be loaded first');

  function defaultBridge() {
    var host = globalThis.flutter_inappwebview;
    return {
      fetch: function (request) {
        return host.callHandler('fushiLnFetch', request);
      },
      persistStorage: function (pluginId, data) {
        return host.callHandler('fushiLnStorage', { id: pluginId, data: data });
      },
    };
  }

  function bridge() {
    return globalThis.__fushiLnReaderBridge || defaultBridge();
  }

  // ── base64 ────────────────────────────────────────────────────────────────

  function bytesToBase64(bytes) {
    var out = '';
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(out);
  }

  function base64ToBytes(value) {
    if (!value) return new Uint8Array(0);
    var raw = atob(value);
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  // ── @libs/fetch ───────────────────────────────────────────────────────────

  function flattenHeaders(source) {
    var out = {};
    if (!source) return out;
    try {
      new Headers(source).forEach(function (value, key) {
        out[key] = value;
      });
    } catch (_) {
      // 非法头名（插件手写的奇怪对象）：逐项尽量保留。
      Object.keys(source).forEach(function (key) {
        out[String(key).toLowerCase()] = String(source[key]);
      });
    }
    return out;
  }

  /**
   * 每个插件一份 `@libs/fetch`：请求带上发起插件的 id 过桥，Dart 侧据此把
   * Cloudflare 挑战记到对应的源上（页面才知道该给哪个源弹「验证」）。
   */
  function createFetchLib(pluginId) {
    async function fetchApi(input, init) {
      init = init || {};
      var url = typeof input === 'string' ? input : (input && input.url) || String(input);
      // 国际化域名（ранобэ.рф）按浏览器规则转成 punycode：原样过桥时 Dart 的 Uri
      // 会把非 ASCII 主机百分号编码，DNS 必然查不到。
      try {
        url = new URL(url).href;
      } catch (_) {}
      var method = String(init.method || (input && input.method) || 'GET').toUpperCase();
      var headers = flattenHeaders(init.headers || (input && input.headers));
      var body = null;
      if (init.body != null && method !== 'GET' && method !== 'HEAD') {
        var normalised = new Request('https://fushi.invalid/', { method: method, body: init.body });
        body = bytesToBase64(new Uint8Array(await normalised.arrayBuffer()));
        var contentType = normalised.headers.get('content-type');
        if (contentType && !('content-type' in headers)) headers['content-type'] = contentType;
      }
      var result = await bridge().fetch({
        url: url,
        method: method,
        headers: headers,
        body: body,
        plugin: pluginId,
      });
      if (!result || result.error) {
        throw new TypeError('Network request failed: ' + ((result && result.error) || 'no response'));
      }
      var status = result.status;
      var nullBody = status === 101 || status === 204 || status === 205 || status === 304;
      var response = new Response(nullBody ? null : base64ToBytes(result.body), {
        status: status < 200 || status > 599 ? 599 : status,
        statusText: result.statusText || '',
        headers: result.headers || {},
      });
      Object.defineProperty(response, 'url', { value: result.url || url });
      return response;
    }

    async function fetchText(url, init, encoding) {
      try {
        var response = await fetchApi(url, init);
        if (!response.ok) return '';
        return new TextDecoder(encoding || 'utf-8').decode(await response.arrayBuffer());
      } catch (_) {
        return '';
      }
    }

    async function fetchFile(url, init) {
      try {
        var response = await fetchApi(url, init);
        if (!response.ok) return '';
        return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
      } catch (_) {
        return '';
      }
    }

    /**
     * gRPC-web 一元调用，与 LNReader app 的 `fetchProto` 同口径：请求 = 1 字节标志
     * + 4 字节大端长度 + protobuf 消息，POST 出去；响应按同一帧格式取第一帧解码。
     */
    async function fetchProto(protoInit, url, init) {
      var root = libs.parseProto(protoInit.proto).root;
      var RequestMessage = root.lookupType(protoInit.requestType);
      if (RequestMessage.verify(protoInit.requestData)) throw new Error('Invalid Proto');
      var encoded = RequestMessage.encode(protoInit.requestData).finish();
      var frame = new Uint8Array(5 + encoded.length);
      new DataView(frame.buffer).setUint32(1, encoded.length);
      frame.set(encoded, 5);
      var options = { method: 'POST' };
      Object.keys(init || {}).forEach(function (key) {
        options[key] = init[key];
      });
      options.body = frame;
      var payload = new Uint8Array(await (await fetchApi(url, options)).arrayBuffer());
      if (payload.length < 5) throw new Error('Empty gRPC-web response');
      var length = new DataView(payload.buffer, payload.byteOffset).getUint32(1);
      return root.lookupType(protoInit.responseType).decode(payload.subarray(5, 5 + length));
    }

    return { fetchApi: fetchApi, fetchText: fetchText, fetchFile: fetchFile, fetchProto: fetchProto };
  }

  // ── 常量模块 ──────────────────────────────────────────────────────────────

  var NovelStatus = {
    Unknown: 'Unknown',
    Ongoing: 'Ongoing',
    Completed: 'Completed',
    Licensed: 'Licensed',
    PublishingFinished: 'Publishing Finished',
    Cancelled: 'Cancelled',
    OnHiatus: 'On Hiatus',
  };
  var FilterTypes = {
    TextInput: 'Text',
    Picker: 'Picker',
    CheckboxGroup: 'Checkbox',
    Switch: 'Switch',
    ExcludableCheckboxGroup: 'XCheckbox',
  };
  var defaultCover =
    'https://github.com/lnreader/lnreader-plugins/blob/master/public/static/coverNotAvailable.webp?raw=true';

  function isUrlAbsolute(url) {
    return typeof url === 'string' && /^[a-z][a-z\d+\-.]*:\/\//i.test(url);
  }

  // ── @libs/storage（每插件一份，同步读写，写后异步落 Dart） ─────────────────

  function createStorage(pluginId, seed) {
    var data = seed && typeof seed === 'object' ? seed : {};
    function persist() {
      try {
        var pending = bridge().persistStorage(pluginId, data);
        if (pending && pending.catch) pending.catch(function () {});
      } catch (_) {}
    }
    var storage = {
      set: function (key, value, expires) {
        var entry = { created: Date.now(), value: value };
        if (expires != null) {
          entry.expires = expires instanceof Date ? expires.getTime() : Number(expires);
        }
        data[key] = entry;
        persist();
      },
      get: function (key, raw) {
        var entry = data[key];
        if (!entry) return undefined;
        if (entry.expires != null && Date.now() > entry.expires) {
          delete data[key];
          persist();
          return undefined;
        }
        return raw ? entry : entry.value;
      },
      delete: function (key) {
        delete data[key];
        persist();
      },
      clearAll: function () {
        Object.keys(data).forEach(function (key) {
          delete data[key];
        });
        persist();
      },
      getAllKeys: function () {
        return Object.keys(data);
      },
    };
    // 站点 WebView 抓取的 local/sessionStorage：本宿主不开站点 WebView，恒空。
    var empty = { get: function () { return undefined; } };
    return { storage: storage, localStorage: empty, sessionStorage: empty };
  }

  // ── require ───────────────────────────────────────────────────────────────

  function makeRequire(pluginId, storageSeed, fetchLib) {
    var storageModule = null;
    var modules = {
      cheerio: libs.cheerio,
      htmlparser2: libs.htmlparser2,
      dayjs: libs.dayjs,
      '@libs/fetch': fetchLib,
      '@libs/novelStatus': { NovelStatus: NovelStatus },
      '@libs/filterInputs': { FilterTypes: FilterTypes },
      '@libs/defaultCover': { defaultCover: defaultCover },
      '@libs/isAbsoluteUrl': { isUrlAbsolute: isUrlAbsolute },
      '@libs/aes': { gcm: libs.gcm },
      '@libs/utils': { utf8ToBytes: libs.utf8ToBytes, bytesToUtf8: libs.bytesToUtf8 },
      urlencode: { encode: encodeURIComponent, decode: decodeURIComponent },
      // 上游 app 的包表里没有它（返回 undefined），两个插件因此坏掉；按其源码
      // 语义补上。
      '@/types/constants': { defaultCover: defaultCover, NovelStatus: NovelStatus },
    };
    return function require(name) {
      if (name === '@libs/storage') {
        if (!storageModule) storageModule = createStorage(pluginId, storageSeed);
        return storageModule;
      }
      if (Object.prototype.hasOwnProperty.call(modules, name)) return modules[name];
      throw new Error('Module not available in Fushi LNReader host: ' + name);
    };
  }

  // ── 插件兼容补丁 ──────────────────────────────────────────────────────────
  //
  // 站点改版把官方插件的某个方法弄坏、而上游仓库还没发修复版时的临时覆盖。
  // 按 `id` + `maxVersion` 匹配：上游一旦发了更高版本，补丁自动退役、用上游的
  // 实现——所以这里只放「上游确认坏了」的方法，不重写插件其余部分。

  function compareVersions(a, b) {
    var left = str(a).split('.');
    var right = str(b).split('.');
    for (var i = 0; i < Math.max(left.length, right.length); i++) {
      var diff = (parseInt(left[i], 10) || 0) - (parseInt(right[i], 10) || 0);
      if (diff) return diff < 0 ? -1 : 1;
    }
    return 0;
  }

  /** Next.js 页面内嵌的 Apollo 缓存（`__NEXT_DATA__`）；取不到返回 `{}`。 */
  function nextApolloState(html) {
    try {
      var raw = libs.cheerio.load(html)('script#__NEXT_DATA__').html();
      var data = JSON.parse(raw || '{}');
      return (data && data.props && data.props.pageProps && data.props.pageProps.__APOLLO_STATE__) || {};
    } catch (_) {
      return {};
    }
  }

  var pluginFixes = [
    {
      // 2026-09 kakuyomu.jp 把排行榜改成 Next.js（CSS 类名带哈希、307 到
      // `?work_variation=long`），插件 1.0.0 的 `.widget-media-genresWorkList-right`
      // 一个都匹配不上，「热门」恒空——源一进去就是空页。排名顺序改从页面内嵌的
      // Apollo 缓存 `rankedWorks(...)` 读（每页 100 部，`?page=N` 翻页）。
      // 详情 / 章节 / 搜索本就读 `__NEXT_DATA__`，实测仍可用，不动。
      id: 'kakuyomu',
      maxVersion: '1.0.0',
      apply: function (plugin, fetchLib) {
        plugin.popularNovels = async function (pageNo, options) {
          var filters = (options && options.filters) || {};
          var genre = (filters.genre && filters.genre.value) || 'all';
          var period = (filters.period && filters.period.value) || 'entire';
          var url = new URL('/rankings/' + genre + '/' + period, plugin.site);
          url.searchParams.set('work_variation', 'long');
          if (pageNo > 1) url.searchParams.set('page', String(pageNo));
          var state = nextApolloState(await fetchLib.fetchText(url.toString()));
          var root = state.ROOT_QUERY || {};
          var key = Object.keys(root).filter(function (name) {
            return name.indexOf('rankedWorks(') === 0;
          })[0];
          var nodes = (key && root[key] && root[key].nodes) || [];
          var novels = [];
          nodes.forEach(function (node) {
            var work = node && state[node.__ref];
            if (!work || !work.id) return;
            novels.push({
              name: str(work.title),
              path: '/works/' + work.id,
              cover: work.adminCoverImageUrl || defaultCover,
            });
          });
          return novels;
        };
      },
    },
  ];

  function applyPluginFixes(plugin, fetchLib) {
    pluginFixes.forEach(function (fix) {
      if (plugin.id === fix.id && compareVersions(plugin.version, fix.maxVersion) <= 0) {
        fix.apply(plugin, fetchLib);
      }
    });
  }

  // ── 插件注册表与调用面 ────────────────────────────────────────────────────

  var plugins = {};

  function pluginFor(id) {
    var plugin = plugins[id];
    if (!plugin) throw new Error('Plugin not loaded: ' + id);
    return plugin;
  }

  function str(value) {
    return value == null ? '' : String(value);
  }

  function optionalStr(value) {
    if (value == null) return null;
    var text = String(value).trim();
    return text ? text : null;
  }

  /**
   * 封面地址按插件站点补全：不少站点在列表里给相对（`/img/x.jpg`）或协议相对
   * （`//cdn…`）地址，LNReader app 的 `<Image>` 也只认绝对地址，原样透传就只能
   * 画占位图。`data:` 与绝对地址不动；补不全就原样返回（由 Dart 侧判不可用）。
   */
  function resolveCover(plugin, cover) {
    var value = optionalStr(cover);
    if (!value || /^(https?:|data:)/i.test(value)) return value;
    try {
      return new URL(value, plugin && plugin.site).toString();
    } catch (_) {
      return value;
    }
  }

  function normaliseItems(items, plugin) {
    if (!Array.isArray(items)) return [];
    return items
      .filter(function (item) {
        return item && item.path != null;
      })
      .map(function (item) {
        return { name: str(item.name).trim(), path: str(item.path), cover: resolveCover(plugin, item.cover) };
      });
  }

  function normaliseChapters(chapters) {
    if (!Array.isArray(chapters)) return [];
    return chapters
      .filter(function (chapter) {
        return chapter && chapter.path != null;
      })
      .map(function (chapter) {
        var number = Number(chapter.chapterNumber);
        return {
          name: str(chapter.name).trim(),
          path: str(chapter.path),
          chapterNumber: isFinite(number) && chapter.chapterNumber != null ? number : null,
          releaseTime: optionalStr(chapter.releaseTime),
          page: optionalStr(chapter.page),
        };
      });
  }

  function defaultFilterValues(filters) {
    var out = {};
    if (!filters || typeof filters !== 'object') return out;
    Object.keys(filters).forEach(function (key) {
      var filter = filters[key];
      if (filter) out[key] = { type: filter.type, value: jsonSafe(filter.value) };
    });
    return out;
  }

  function jsonSafe(value) {
    try {
      return JSON.parse(JSON.stringify(value == null ? null : value));
    } catch (_) {
      return null;
    }
  }

  var api = {
    /** 装载插件源码；返回插件自报的元数据。重复装载同 id 即替换。 */
    load: function (id, code, storageSeed) {
      var module = { exports: {} };
      // 插件里裸调的 `fetch`：LNReader app 跑在 React Native 里，全局 fetch 是原生
      // 网络、没有 CORS，少数插件（ixdzs8 / daotekno / rainofsnow 等）就直接用它。
      // 本宿主页被 CSP 封了网络，原生 fetch 必失败——给插件一个同名形参，走宿主桥。
      var factory = new Function(
        'require',
        'module',
        'exports',
        'fetch',
        String(code) + '\n;return module.exports.default || exports.default;',
      );
      var fetchLib = createFetchLib(id);
      var plugin = factory(makeRequire(id, storageSeed, fetchLib), module, module.exports, fetchLib.fetchApi);
      if (!plugin || typeof plugin.popularNovels !== 'function') {
        throw new Error('Not an LNReader plugin: ' + id);
      }
      applyPluginFixes(plugin, fetchLib);
      plugins[id] = plugin;
      return api.describe(id);
    },

    unload: function (id) {
      delete plugins[id];
      return true;
    },

    isLoaded: function (id) {
      return Object.prototype.hasOwnProperty.call(plugins, id);
    },

    describe: function (id) {
      var plugin = pluginFor(id);
      return {
        id: str(plugin.id || id),
        name: str(plugin.name),
        site: str(plugin.site),
        version: str(plugin.version),
        filters: jsonSafe(plugin.filters) || null,
        pluginSettings: jsonSafe(plugin.pluginSettings) || null,
        imageHeaders: flattenHeaders(plugin.imageRequestInit && plugin.imageRequestInit.headers),
        hasParsePage: typeof plugin.parsePage === 'function',
      };
    },

    /**
     * 热门 / 最新一页。`filterValues` 为 `{key: {type, value}}`（不带 label /
     * options）；缺省时与 LNReader app 同口径**补插件自带的默认值**——插件普遍
     * 直接读 `filters.genre.value`，不传就 TypeError（真 Syosetu 插件实测）。
     */
    popular: async function (id, page, showLatest, filterValues) {
      var plugin = pluginFor(id);
      var filters = defaultFilterValues(plugin.filters);
      if (filterValues) {
        Object.keys(filterValues).forEach(function (key) {
          filters[key] = filterValues[key];
        });
      }
      var options = { showLatestNovels: !!showLatest, filters: filters };
      return normaliseItems(await plugin.popularNovels(page, options), plugin);
    },

    search: async function (id, term, page) {
      var plugin = pluginFor(id);
      return normaliseItems(await plugin.searchNovels(term, page), plugin);
    },

    novel: async function (id, path) {
      var plugin = pluginFor(id);
      var novel = (await plugin.parseNovel(path)) || {};
      var totalPages = Number(novel.totalPages);
      return {
        name: str(novel.name).trim(),
        path: str(novel.path || path),
        cover: resolveCover(plugin, novel.cover),
        genres: optionalStr(novel.genres),
        summary: optionalStr(novel.summary),
        author: optionalStr(novel.author),
        artist: optionalStr(novel.artist),
        status: optionalStr(novel.status),
        chapters: normaliseChapters(novel.chapters),
        totalPages: isFinite(totalPages) && totalPages > 0 ? Math.floor(totalPages) : 1,
      };
    },

    page: async function (id, path, page) {
      var plugin = pluginFor(id);
      if (typeof plugin.parsePage !== 'function') return [];
      var result = (await plugin.parsePage(path, String(page))) || {};
      return normaliseChapters(result.chapters);
    },

    chapter: async function (id, path) {
      return str(await pluginFor(id).parseChapter(path));
    },

    /** 与 LNReader app 同口径：插件有 resolveUrl 用它，否则 site + path。 */
    resolveUrl: function (id, path, isNovel) {
      var plugin = pluginFor(id);
      if (isUrlAbsolute(path)) return path;
      if (typeof plugin.resolveUrl === 'function') {
        return str(plugin.resolveUrl(path, !!isNovel));
      }
      try {
        return new URL(path, plugin.site).toString();
      } catch (_) {
        return str(plugin.site) + str(path);
      }
    },

    /**
     * 章节 HTML → EPUB 可用的 XHTML 片段（body 的内部）。
     *
     * 去掉脚本 / 样式 / 表单 / 内嵌框架与 on* 属性；图片 src 解析成绝对地址后换成
     * `${imagePrefix}${n}${ext}`，原地址随 `images` 返回，由 Dart 下载后按同名写进
     * EPUB。XMLSerializer 保证输出是良构 XHTML（`<br/>`、实体转义）。
     */
    toXhtml: function (html, baseUrl, imagePrefix) {
      var doc = new DOMParser().parseFromString(str(html), 'text/html');
      var body = doc.body;
      var drop = body.querySelectorAll(
        'script,style,link,meta,iframe,frame,object,embed,form,input,button,select,textarea,noscript,template,svg,video,audio,canvas',
      );
      for (var d = 0; d < drop.length; d++) drop[d].remove();
      var all = body.querySelectorAll('*');
      for (var a = 0; a < all.length; a++) {
        var element = all[a];
        var names = [];
        for (var n = 0; n < element.attributes.length; n++) names.push(element.attributes[n].name);
        for (var k = 0; k < names.length; k++) {
          var name = names[k].toLowerCase();
          if (name.indexOf('on') === 0 || name === 'style' || name === 'class' || name === 'id') {
            element.removeAttribute(names[k]);
          }
        }
      }
      var links = body.querySelectorAll('a');
      for (var l = 0; l < links.length; l++) links[l].removeAttribute('href');
      var images = [];
      var imgs = body.querySelectorAll('img');
      for (var i = 0; i < imgs.length; i++) {
        var img = imgs[i];
        var src = img.getAttribute('src') || img.getAttribute('data-src') || '';
        var absolute = '';
        try {
          absolute = new URL(src, baseUrl).toString();
        } catch (_) {}
        var kept = ['alt'];
        var attrNames = [];
        for (var m = 0; m < img.attributes.length; m++) attrNames.push(img.attributes[m].name);
        attrNames.forEach(function (attr) {
          if (kept.indexOf(attr) < 0) img.removeAttribute(attr);
        });
        if (!/^https?:/i.test(absolute)) {
          img.remove();
          continue;
        }
        var ext = (/\.(jpe?g|png|gif|webp)(?:[?#]|$)/i.exec(absolute) || [])[1] || 'jpg';
        var fileName = str(imagePrefix) + images.length + '.' + ext.toLowerCase().replace('jpeg', 'jpg');
        img.setAttribute('src', fileName);
        if (!img.hasAttribute('alt')) img.setAttribute('alt', '');
        images.push({ url: absolute, fileName: fileName });
      }
      var serializer = new XMLSerializer();
      var out = '';
      for (var c = 0; c < body.childNodes.length; c++) {
        out += serializer.serializeToString(body.childNodes[c]);
      }
      // XMLSerializer 给 HTML 节点带上 XHTML 命名空间声明；外层 <html> 已声明，去重。
      out = out.replace(/ xmlns="http:\/\/www\.w3\.org\/1999\/xhtml"/g, '');
      return { xhtml: out, images: images };
    },
  };

  globalThis.__fushiLnReader = api;
})();
