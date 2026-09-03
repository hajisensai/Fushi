// frame-capture.js 的行为测试：从 `<video>` 取当前解码帧当制卡封面。
//
// 三条不变式，每条都对应一个真实会出错的形状：
//   1. 尺寸取的是 `videoWidth/videoHeight`（流的原生分辨率），不是元素的 CSS 尺寸——否则
//      小窗播放时封面会变成一张缩略图，而用户看的明明是 4K 源。
//   2. 取不到就返回 null，**绝不退化成截屏/黑图**：DRM 视频的 canvas 会抛 SecurityError，
//      未加载的 video 的 videoWidth 是 0。两者都必须判失败让上层降级。
//   3. 只缩不放：源比上限小的时候原样输出，不做无中生有的放大。
//   4. DRM 的**另一半**失败形态：canvas 不被污染、什么都不抛，但画出来是一整块常量黑
//      （硬解 EME 合成路径的典型行为）。必须同样判失败，否则用户静默拿到纯黑封面的卡。
//      判据保守到「全黑 + 零方差」——正常暗场景（带噪声/渐变）不许被误伤。
const { test } = require('node:test');
const assert = require('node:assert');
const {
  FUSHI_FRAME_MAX_LONG_EDGE,
  FUSHI_FRAME_BLACK_LUMA_MAX,
  FUSHI_FRAME_BLACK_SAMPLE_GRID,
  fushiFrameTargetSize,
  fushiDataUrlToBase64,
  fushiVideoFrameCapturable,
  fushiCaptureVideoFrame,
  fushiSamplesAreUniformBlack,
  fushiSampleCanvasPixels,
} = require('./frame-capture.js');

// 最小 video 替身：只实现取帧真正读的三个属性。
function fakeVideo({ w = 1920, h = 1080, readyState = 2 } = {}) {
  return { videoWidth: w, videoHeight: h, readyState };
}

// 最小 canvas/document 替身。`throwOn` 让某一步抛，模拟 DRM 污染与实现上限。
function installFakeDocument({ throwOn = null, dataUrl = 'data:image/jpeg;base64,QUJD', pixelAt = null } = {}) {
  const drawn = [];
  const canvases = [];
  const reads = [];
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
            // `pixelAt` 为 null 时整个 getImageData 不存在（老浏览器形状）——取帧照旧，
            // 只是不做黑帧判定。
            ...(pixelAt
              ? {
                getImageData(x, y, w, h) {
                  if (throwOn === 'getImageData') {
                    const e = new Error('tainted canvas');
                    e.name = 'SecurityError';
                    throw e;
                  }
                  reads.push([x, y, w, h]);
                  return { data: Uint8ClampedArray.from(pixelAt(x, y)) };
                },
              }
              : {}),
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
  return { drawn, canvases, reads };
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

// ---- DRM 黑帧（文件头承诺的第二种失败形态）----

test('全黑且零方差 → 判黑帧', () => {
  const black = new Array(64).fill([0, 0, 0]);
  assert.strictEqual(fushiSamplesAreUniformBlack(black, FUSHI_FRAME_BLACK_LUMA_MAX), true);
  // 极暗但仍常量（阈值内）也算——DRM 合成失败偶尔给的是 (1,1,1) 之类。
  assert.strictEqual(
    fushiSamplesAreUniformBlack(new Array(64).fill([2, 2, 2]), FUSHI_FRAME_BLACK_LUMA_MAX),
    true);
});

test('正常暗场景不被误伤：够黑但有方差 → 不判黑帧', () => {
  // 全部低于亮度阈值，但像素不完全相同（真实编码噪声就是这个形状）。
  const noisy = new Array(64).fill(null).map((_, i) => (i === 40 ? [0, 0, 1] : [0, 0, 0]));
  assert.strictEqual(fushiSamplesAreUniformBlack(noisy, FUSHI_FRAME_BLACK_LUMA_MAX), false,
    '零方差是硬条件——只要有一个采样点不同就不许判失败');
});

test('常量但不够黑（纯色画面/白场）→ 不判黑帧', () => {
  assert.strictEqual(
    fushiSamplesAreUniformBlack(new Array(64).fill([255, 255, 255]), FUSHI_FRAME_BLACK_LUMA_MAX),
    false);
  // 亮度阈值走 BT.601：纯蓝 (0,0,255) 亮度 29 > 4，不是黑。
  assert.strictEqual(
    fushiSamplesAreUniformBlack(new Array(64).fill([0, 0, 255]), FUSHI_FRAME_BLACK_LUMA_MAX),
    false);
});

test('采样点不足/形状不对 → 不判失败（判不出来就不判）', () => {
  assert.strictEqual(fushiSamplesAreUniformBlack([[0, 0, 0]], 4), false, '单点无从谈方差');
  assert.strictEqual(fushiSamplesAreUniformBlack([], 4), false);
  assert.strictEqual(fushiSamplesAreUniformBlack(null, 4), false);
  assert.strictEqual(fushiSamplesAreUniformBlack([[0, 0], [0, 0]], 4), false);
});

test('抽稀采样：GRID×GRID 个点、全部落在画布内、不整幅读回', () => {
  const ctx = {
    getImageData(x, y) { return { data: [x % 256, y % 256, 0, 255] }; },
  };
  const out = fushiSampleCanvasPixels(ctx, 1920, 1080, FUSHI_FRAME_BLACK_SAMPLE_GRID);
  assert.strictEqual(out.length, FUSHI_FRAME_BLACK_SAMPLE_GRID ** 2);
  const ctx2 = {
    reads: [],
    getImageData(x, y, w, h) { this.reads.push([x, y, w, h]); return { data: [0, 0, 0, 255] }; },
  };
  fushiSampleCanvasPixels(ctx2, 1920, 1080, 8);
  for (const [x, y, w, h] of ctx2.reads) {
    assert.ok(x >= 0 && x < 1920, `x 越界: ${x}`);
    assert.ok(y >= 0 && y < 1080, `y 越界: ${y}`);
    assert.strictEqual(w, 1, '必须是 1×1 抽稀读，不是整幅 8MB 读回');
    assert.strictEqual(h, 1);
  }
});

test('没有 getImageData（老浏览器）→ null，不阻断出卡', () => {
  assert.strictEqual(fushiSampleCanvasPixels({}, 1920, 1080), null);
  assert.strictEqual(fushiSampleCanvasPixels(null, 1920, 1080), null);
  assert.strictEqual(fushiSampleCanvasPixels({ getImageData() {} }, 0, 0), null);
});

test('DRM 黑帧：canvas 不抛但画出全黑 → null，绝不把纯黑封面塞进卡', () => {
  installFakeDocument({ pixelAt: () => [0, 0, 0, 255] });
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo()), null,
    '这是本 PR 的 B2：文件头承诺「两种都判失败」，此前只处理了 SecurityError 那一种');
});

test('正常暗场景仍然出图：够黑但有噪声 → 照常返回封面', () => {
  // 够黑（蓝通道 0/1 → 亮度 <= 0.114）但采样点之间不完全相同：真实暗场景的形状。
  installFakeDocument({ pixelAt: (x) => [0, 0, Math.floor(x / 500) % 2, 255] });
  const out = fushiCaptureVideoFrame(fakeVideo());
  assert.ok(out && out.base64 === 'QUJD', '有方差就不是 DRM 黑帧，不许误伤');
});

test('正常亮画面照常出图（黑帧判定不误伤普通帧）', () => {
  installFakeDocument({ pixelAt: () => [128, 130, 127, 255] });
  const out = fushiCaptureVideoFrame(fakeVideo());
  assert.ok(out && out.base64 === 'QUJD');
});

test('getImageData 抛 SecurityError（污染的另一种时机）→ null', () => {
  installFakeDocument({ pixelAt: () => [0, 0, 0, 255], throwOn: 'getImageData' });
  assert.strictEqual(fushiCaptureVideoFrame(fakeVideo()), null);
});

test('canvas 无 getImageData 时取帧路径不变（向后兼容）', () => {
  installFakeDocument();
  const out = fushiCaptureVideoFrame(fakeVideo());
  assert.ok(out && out.base64 === 'QUJD', '判不了黑帧就不判，不能因此拒绝出卡');
});
