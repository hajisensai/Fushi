// frame-capture.js 的行为测试：从 `<video>` 取当前解码帧当制卡封面。
//
// 三条不变式，每条都对应一个真实会出错的形状：
//   1. 尺寸取的是 `videoWidth/videoHeight`（流的原生分辨率），不是元素的 CSS 尺寸——否则
//      小窗播放时封面会变成一张缩略图，而用户看的明明是 4K 源。
//   2. 取不到就返回 null，**绝不退化成截屏/黑图**：DRM 视频的 canvas 会抛 SecurityError，
//      未加载的 video 的 videoWidth 是 0。两者都必须判失败让上层降级。
//   3. 只缩不放：源比上限小的时候原样输出，不做无中生有的放大。
const { test } = require('node:test');
const assert = require('node:assert');
const {
  FUSHI_FRAME_MAX_LONG_EDGE,
  fushiFrameTargetSize,
  fushiDataUrlToBase64,
  fushiVideoFrameCapturable,
  fushiCaptureVideoFrame,
} = require('./frame-capture.js');

// 最小 video 替身：只实现取帧真正读的三个属性。
function fakeVideo({ w = 1920, h = 1080, readyState = 2 } = {}) {
  return { videoWidth: w, videoHeight: h, readyState };
}

// 最小 canvas/document 替身。`throwOn` 让某一步抛，模拟 DRM 污染与实现上限。
function installFakeDocument({ throwOn = null, dataUrl = 'data:image/jpeg;base64,QUJD' } = {}) {
  const drawn = [];
  const canvases = [];
  global.document = {
    createElement(tag) {
      assert.strictEqual(tag, 'canvas');
      const canvas = {
        width: 0,
        height: 0,
        getContext(kind) {
          assert.strictEqual(kind, '2d');
          if (throwOn === 'getContext') throw new Error('no ctx');
          return {
            imageSmoothingEnabled: false,
            imageSmoothingQuality: 'low',
            drawImage(...args) {
              if (throwOn === 'drawImage') throw new Error('tainted');
              drawn.push(args);
            },
          };
        },
        toDataURL() {
          // 真实浏览器里 DRM 污染的 canvas 正是在这一步抛 SecurityError。
          if (throwOn === 'toDataURL') {
            const e = new Error('tainted canvas');
            e.name = 'SecurityError';
            throw e;
          }
          return dataUrl;
        },
      };
      canvases.push(canvas);
      return canvas;
    },
  };
  return { drawn, canvases };
}

test('目标尺寸取流的原生分辨率，长边超上限才等比缩', () => {
  // 1080p：长边 1920 == 上限 → 原样，不缩。
  assert.deepStrictEqual(fushiFrameTargetSize(1920, 1080, FUSHI_FRAME_MAX_LONG_EDGE),
    { width: 1920, height: 1080, scaled: false });
  // 4K：长边 3840 → 缩到 1920，高度等比 1080。
  assert.deepStrictEqual(fushiFrameTargetSize(3840, 2160, FUSHI_FRAME_MAX_LONG_EDGE),
    { width: 1920, height: 1080, scaled: true });
  // 竖屏：长边是高，按高缩。
  assert.deepStrictEqual(fushiFrameTargetSize(1080, 3840, FUSHI_FRAME_MAX_LONG_EDGE),
    { width: 540, height: 1920, scaled: true });
});

test('小于上限只原样返回，绝不放大', () => {
  const r = fushiFrameTargetSize(640, 360, FUSHI_FRAME_MAX_LONG_EDGE);
  assert.deepStrictEqual(r, { width: 640, height: 360, scaled: false });
});

test('极端长条比例缩完仍至少 1px（canvas 尺寸 0 是非法的）', () => {
  const r = fushiFrameTargetSize(10000, 3, 1920);
  assert.strictEqual(r.width, 1920);
  assert.ok(r.height >= 1, `高度必须 >= 1，实际 ${r.height}`);
});

test('尺寸未知（video 尚未拿到元数据）→ null，不是 0×0 画布', () => {
  assert.strictEqual(fushiFrameTargetSize(0, 0, 1920), null);
  assert.strictEqual(fushiFrameTargetSize(NaN, 1080, 1920), null);
  assert.strictEqual(fushiFrameTargetSize(-1, 1080, 1920), null);
});

test('可取帧探测：要有尺寸且 readyState>=2', () => {
  assert.strictEqual(fushiVideoFrameCapturable(fakeVideo()), true);
  assert.strictEqual(fushiVideoFrameCapturable(fakeVideo({ readyState: 1 })), false,
    'HAVE_METADATA 时当前帧还没解码出来');
  assert.strictEqual(fushiVideoFrameCapturable(fakeVideo({ w: 0, h: 0 })), false);
  assert.strictEqual(fushiVideoFrameCapturable(null), false);
});

test('data URL 解析：非图片 / 空 base64 段一律 null', () => {
  assert.strictEqual(fushiDataUrlToBase64('data:image/jpeg;base64,QUJD'), 'QUJD');
  assert.strictEqual(fushiDataUrlToBase64('data:image/jpeg;base64,'), null);
  assert.strictEqual(fushiDataUrlToBase64('data:text/html,hi'), null);
  assert.strictEqual(fushiDataUrlToBase64('QUJD'), null);
  assert.strictEqual(fushiDataUrlToBase64(null), null);
});

test('取帧：按原生分辨率画，回传源尺寸与输出尺寸', () => {
  const { drawn, canvases } = installFakeDocument();
  const out = fushiCaptureVideoFrame(fakeVideo({ w: 3840, h: 2160 }));
  assert.strictEqual(out.base64, 'QUJD');
  assert.strictEqual(out.sourceWidth, 3840, '源尺寸必须回传，用于诊断封面是几分之几');
  assert.strictEqual(out.sourceHeight, 2160);
  assert.strictEqual(out.width, 1920);
  assert.strictEqual(out.height, 1080);
  assert.strictEqual(canvases[0].width, 1920, 'canvas 尺寸必须等于目标尺寸');
  assert.strictEqual(canvases[0].height, 1080);
  // drawImage 的目标矩形就是整块画布——不裁剪、不留边。
  assert.deepStrictEqual(drawn[0].slice(1), [0, 0, 1920, 1080]);
});

test('DRM 污染：toDataURL 抛 SecurityError → null，绝不退化成截屏或黑图', () => {
  installFakeDocument({ throwOn: 'toDataURL' });
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo()), null);
});

test('drawImage 抛（跨源污染的另一种时机）→ null', () => {
  installFakeDocument({ throwOn: 'drawImage' });
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo()), null);
});

test('拿不到 2d context → null，不抛', () => {
  installFakeDocument({ throwOn: 'getContext' });
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo()), null);
});

test('video 未就绪 → null，且根本不碰 canvas', () => {
  const { canvases } = installFakeDocument();
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo({ readyState: 0 })), null);
  assert.strictEqual(fushiCaptureVideoFrame(null), null);
  assert.strictEqual(canvases.length, 0, '未就绪就不该创建画布');
});

test('canvas 画出退化空串 → null（不把空图当封面塞进卡）', () => {
  installFakeDocument({ dataUrl: 'data:image/jpeg;base64,' });
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo()), null);
});
