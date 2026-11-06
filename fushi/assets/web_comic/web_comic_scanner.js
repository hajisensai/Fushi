// Fushi web comic scanner.
//
// Injected by Fushi into a manga site's chapter page (in-app browser and the
// headless chapter scanner). It collects the chapter's page images in reading
// order and reports them back through a flutter_inappwebview JS handler:
//
//   { requestId, pageUrl, title, images: [{url, w, h}], nextChapterUrl,
//     prevChapterUrl, ruleId, userAgent, error }
//
// Two modes:
//   - site rule (assets/web_comic/site_rules.json): dom / global / api / script;
//   - generic: scroll through the page to trigger lazy loading, read src and
//     the usual lazy-load attributes, keep images that are large both as a
//     file (natural size) and on screen (display size), dedupe in order.
//
// Written for Fushi from scratch; the page is untrusted, so Dart re-validates
// and re-filters everything this script reports.
(function () {
  'use strict';
  var VERSION = 1;
  if (window.__fushiWebComic && window.__fushiWebComic.version === VERSION) {
    return;
  }

  var LAZY_ATTRIBUTES = [
    'data-src',
    'data-original',
    'data-lazy-src',
    'data-lazy',
    'data-url',
    'data-echo',
    'data-actualsrc',
    'data-cfsrc',
    'data-full',
    'data-img',
    'lazy-src',
    'file',
    '_src',
  ];

  var NEXT_WORDS = [
    '下一话', '下一話', '下一章', '下一回', '下一集', '下一卷',
    '次の話', '次話', '次のエピソード',
    'next chapter', 'next episode', 'next ch',
    '다음화', '다음 화',
  ];
  var PREV_WORDS = [
    '上一话', '上一話', '上一章', '上一回', '上一集', '上一卷',
    '前の話', '前話', '前のエピソード',
    'previous chapter', 'prev chapter', 'previous episode', 'prev ch',
    '이전화', '이전 화',
  ];

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  function usableUrl(value) {
    if (!value) return null;
    var text = String(value).trim();
    if (!text || /^(data|blob|javascript|about):/i.test(text)) return null;
    return text;
  }

  // "a.jpg 1x, b.jpg 2x" / "a.jpg 400w, b.jpg 1200w" -> the largest candidate.
  function largestFromSrcset(srcset) {
    if (!srcset) return null;
    var best = null;
    var bestScore = -1;
    String(srcset)
      .split(',')
      .forEach(function (part) {
        var bits = part.trim().split(/\s+/);
        var url = usableUrl(bits[0]);
        if (!url) return;
        var score = 1;
        var descriptor = bits[1] || '';
        var match = /^([\d.]+)([wx])$/i.exec(descriptor);
        if (match) score = parseFloat(match[1]) * (match[2] === 'w' ? 1 : 1000);
        if (score > bestScore) {
          bestScore = score;
          best = url;
        }
      });
    return best;
  }

  function lazyUrl(element) {
    for (var i = 0; i < LAZY_ATTRIBUTES.length; i++) {
      var url = usableUrl(element.getAttribute(LAZY_ATTRIBUTES[i]));
      if (url) return url;
    }
    return (
      largestFromSrcset(element.getAttribute('data-srcset')) ||
      largestFromSrcset(element.getAttribute('srcset'))
    );
  }

  // A loaded <img> reports its real file; an unloaded lazy one only has the
  // attribute that will become its src.
  function imageUrl(img) {
    var current = usableUrl(img.currentSrc || img.getAttribute('src'));
    if (current && img.complete && img.naturalWidth > 1) return current;
    return lazyUrl(img) || current;
  }

  function absolute(url) {
    try {
      return new URL(url, location.href).href;
    } catch (_) {
      return null;
    }
  }

  function collectGeneric(minNatural, minDisplay) {
    var out = [];
    var seen = {};
    var images = document.querySelectorAll('img');
    for (var i = 0; i < images.length; i++) {
      var img = images[i];
      var url = imageUrl(img);
      var abs = url && absolute(url);
      if (!abs || seen[abs]) continue;
      var rect = img.getBoundingClientRect();
      var displayLong = Math.max(rect.width, rect.height);
      if (displayLong < minDisplay) continue;
      var loaded = img.complete && img.naturalWidth > 0;
      if (loaded) {
        if (Math.max(img.naturalWidth, img.naturalHeight) < minNatural) continue;
      }
      seen[abs] = true;
      out.push({
        url: abs,
        w: loaded ? img.naturalWidth : 0,
        h: loaded ? img.naturalHeight : 0,
      });
    }
    return out;
  }

  // Scroll down in screen-sized steps so IntersectionObserver / scroll based
  // lazy loaders fire, then go back to where the reader was.
  async function triggerLazyLoad(budgetMs) {
    var root = document.scrollingElement || document.documentElement;
    if (!root) return;
    var origin = window.scrollY;
    var started = Date.now();
    var lastHeight = -1;
    while (Date.now() - started < budgetMs) {
      window.scrollBy(0, Math.max(240, window.innerHeight * 0.9));
      await sleep(120);
      var atBottom = window.innerHeight + window.scrollY >= root.scrollHeight - 4;
      if (atBottom) {
        if (root.scrollHeight === lastHeight) break;
        lastHeight = root.scrollHeight;
        await sleep(350);
      }
    }
    window.scrollTo(0, origin);
  }

  async function waitForImagesToSettle(budgetMs) {
    var started = Date.now();
    while (Date.now() - started < budgetMs) {
      var pending = 0;
      var images = document.querySelectorAll('img');
      for (var i = 0; i < images.length; i++) {
        var img = images[i];
        if (!img.complete && usableUrl(img.currentSrc || img.getAttribute('src'))) {
          pending++;
        }
      }
      if (pending === 0) return;
      await sleep(200);
    }
  }

  function getPath(value, path) {
    if (value == null || !path) return value;
    var parts = String(path).split('.');
    var current = value;
    for (var i = 0; i < parts.length; i++) {
      if (current == null) return undefined;
      var key = parts[i];
      if (key === '') continue;
      current = current[key];
    }
    return current;
  }

  function asText(value) {
    if (value == null) return '';
    return typeof value === 'object' ? JSON.stringify(value) : String(value);
  }

  // {item} {item.x} {$a.b} {origin} {groupName}
  function fill(template, groups, item, json) {
    return String(template).replace(/\{([^{}]+)\}/g, function (whole, key) {
      if (key === 'item') return asText(item);
      if (key.indexOf('item.') === 0) return asText(getPath(item, key.slice(5)));
      if (key.charAt(0) === '$') return asText(getPath(json, key.slice(1)));
      if (key === 'origin') return location.origin;
      if (groups && Object.prototype.hasOwnProperty.call(groups, key)) {
        return asText(groups[key]);
      }
      return whole;
    });
  }

  function chapterGroups(rule) {
    try {
      var match = new RegExp(rule.chapterUrlPattern).exec(
        location.pathname + location.search,
      );
      return (match && match.groups) || {};
    } catch (_) {
      return {};
    }
  }

  async function waitFor(check, budgetMs) {
    var started = Date.now();
    var value = check();
    while (!value && Date.now() - started < budgetMs) {
      await sleep(200);
      value = check();
    }
    return value;
  }

  async function collectByRule(rule, options, scriptFn) {
    var source = rule.images || {};
    var groups = chapterGroups(rule);
    var urls = [];
    if (source.mode === 'dom') {
      if (source.scroll) await triggerLazyLoad(options.scrollBudgetMs);
      var nodes = await waitFor(function () {
        var found = document.querySelectorAll(source.selector);
        return found.length ? found : null;
      }, options.waitMs);
      var attributes = source.attributes || ['src'];
      for (var i = 0; nodes && i < nodes.length; i++) {
        var node = nodes[i];
        var url = null;
        for (var a = 0; a < attributes.length && !url; a++) {
          url = usableUrl(node.getAttribute(attributes[a]));
        }
        if (!url && node.tagName === 'IMG') url = imageUrl(node);
        if (url) urls.push(url);
      }
    } else if (source.mode === 'global') {
      var value = await waitFor(function () {
        return getPath(window, source.path);
      }, options.waitMs);
      var items = [];
      if (Array.isArray(value)) {
        items = value;
      } else if (typeof value === 'string' && source.regex) {
        var re = new RegExp(source.regex, 'g');
        var m;
        while ((m = re.exec(value)) !== null) {
          items.push(m[1] !== undefined ? m[1] : m[0]);
          if (m[0] === '') re.lastIndex++;
        }
      }
      items.forEach(function (item) {
        urls.push(source.imageTemplate ? fill(source.imageTemplate, groups, item, null) : asText(item));
      });
    } else if (source.mode === 'api') {
      var init = { method: source.method || 'GET', credentials: 'include' };
      if (source.contentType) init.headers = { 'content-type': source.contentType };
      if (source.body) init.body = fill(source.body, groups, null, null);
      var response = await fetch(fill(source.url, groups, null, null), init);
      if (!response.ok) throw new Error('api ' + response.status);
      var json = await response.json();
      var list = getPath(json, source.itemsPath);
      if (!Array.isArray(list)) throw new Error('api items missing');
      list.forEach(function (item) {
        urls.push(fill(source.imageTemplate || '{item}', groups, item, json));
      });
    } else if (source.mode === 'script' && scriptFn) {
      var result = await scriptFn({ groups: groups, origin: location.origin });
      if (Array.isArray(result)) {
        result.forEach(function (item) {
          urls.push(asText(item));
        });
      }
    }
    var out = [];
    var seen = {};
    urls.forEach(function (url) {
      var abs = absolute(url);
      if (!abs || seen[abs]) return;
      seen[abs] = true;
      out.push({ url: abs, w: 0, h: 0 });
    });
    return out;
  }

  function linkText(anchor) {
    return [
      anchor.textContent,
      anchor.getAttribute('title'),
      anchor.getAttribute('aria-label'),
    ]
      .filter(Boolean)
      .join(' ')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();
  }

  function hrefOf(element) {
    if (!element) return null;
    var anchor = element.closest ? element.closest('a[href]') || element : element;
    var href = anchor.href || anchor.getAttribute('href');
    if (!href || /^javascript:/i.test(href) || href === '#') return null;
    return absolute(href);
  }

  function findChapterLink(selector, words) {
    if (selector) {
      try {
        var hit = hrefOf(document.querySelector(selector));
        if (hit) return hit;
      } catch (_) {
        // A broken selector falls back to the generic search.
      }
    }
    var anchors = document.querySelectorAll('a[href]');
    for (var i = 0; i < anchors.length; i++) {
      var text = linkText(anchors[i]);
      if (!text || text.length > 24) continue;
      for (var w = 0; w < words.length; w++) {
        if (text.indexOf(words[w]) >= 0) {
          var href = hrefOf(anchors[i]);
          if (href && href !== location.href) return href;
        }
      }
    }
    return null;
  }

  function post(handler, payload) {
    var bridge = window.flutter_inappwebview;
    if (bridge && bridge.callHandler) {
      bridge.callHandler(handler, payload);
      return;
    }
    window.addEventListener(
      'flutterInAppWebViewPlatformReady',
      function () {
        window.flutter_inappwebview.callHandler(handler, payload);
      },
      { once: true },
    );
  }

  async function scan(config, scriptFn) {
    var options = {
      minNaturalSide: config.minNaturalSide || 500,
      minDisplaySide: config.minDisplaySide || 100,
      scrollBudgetMs: config.scrollBudgetMs || 8000,
      waitMs: config.waitMs || 6000,
    };
    var rule = config.rule || null;
    var result = {
      requestId: config.requestId,
      pageUrl: location.href,
      title: document.title || '',
      images: [],
      nextChapterUrl: null,
      prevChapterUrl: null,
      ruleId: rule ? rule.id : null,
      userAgent: navigator.userAgent,
      generic: !rule,
      error: null,
    };
    try {
      if (rule) {
        result.images = await collectByRule(rule, options, scriptFn);
      }
      if (!result.images.length) {
        // No rule, or the rule found nothing (site redesign): generic scan.
        // ruleId stays set so Dart still applies the rule's referer / headers.
        result.generic = true;
        await waitFor(function () {
          return collectGeneric(0, options.minDisplaySide).length > 0;
        }, options.waitMs);
        if (config.scroll !== false) await triggerLazyLoad(options.scrollBudgetMs);
        await waitForImagesToSettle(2000);
        result.images = collectGeneric(options.minNaturalSide, options.minDisplaySide);
      }
      result.nextChapterUrl = findChapterLink(rule && rule.nextSelector, NEXT_WORDS);
      result.prevChapterUrl = findChapterLink(rule && rule.prevSelector, PREV_WORDS);
    } catch (error) {
      result.error = String((error && error.message) || error);
    }
    post(config.handler, result);
    return true;
  }

  window.__fushiWebComic = { version: VERSION, scan: scan };
})();
