// 处理台共用的全屏看图（反馈截图、拍板台的图片附件与原文图片都走这里）。
//
// 处理台页面默认没有脚本（CSP script-src 为 none），看图用 CSS `:target`：缩略图是指向
// `#<id>` 的链接，命中的遮罩层铺满视口；右上角 × 与遮罩空白处都是指回缩略图锚点的链接，
// 点了就关、页面停在原来的位置；浏览器「返回」同样关闭（hash 进了历史）。「原图」在新标签
// 页打开，要放大细看用浏览器自己的缩放。此前缩略图直接链到附件 URL，同一标签页里整页跳成
// 裸图片，没有任何关闭入口，只能按浏览器返回键退出（反馈 vh4K5khfVr）。
//
// 遮罩里的 <img> 带 loading="lazy"：遮罩未打开时 display:none，浏览器不会提前下载第二份。

import { esc } from './pages.js';

export const LIGHTBOX_STYLE = `
.lb-thumb{display:inline-block;scroll-margin-top:64px}
.lb{display:none}
.lb:target{display:flex;position:fixed;inset:0;z-index:1000;align-items:center;justify-content:center;padding:48px 16px 16px;background:rgba(0,0,0,.88)}
.lb-bg{position:absolute;inset:0;cursor:zoom-out}
/* 压过各页缩略图样式（.shots img / .dshots img / .dfile img 的尺寸上限与描边）。 */
.lb:target img{position:relative;display:block;margin:0;border:0;max-width:100%;max-height:100%;object-fit:contain;border-radius:4px;box-shadow:0 4px 24px rgba(0,0,0,.5)}
.lb-x,.lb-orig{position:absolute;top:8px;color:#fff;text-decoration:none;background:rgba(255,255,255,.14);border-radius:999px}
.lb-x{right:12px;width:40px;height:40px;display:flex;align-items:center;justify-content:center;font-size:26px;line-height:1}
.lb-orig{right:62px;height:40px;padding:0 14px;display:flex;align-items:center;font-size:14px}
.lb-x:hover,.lb-orig:hover,.lb-x:focus-visible,.lb-orig:focus-visible{background:rgba(255,255,255,.28)}
`;

/**
 * 一张可点开全屏查看的图片：缩略图链接 + 对应的全屏遮罩。
 *
 * @param {{ id: string, src: string, alt: string, imgAttrs?: string }} image
 *   id：页内唯一、只含 [A-Za-z0-9_-]；imgAttrs：原样追加到两处 <img> 上的额外属性（调用方负责转义，
 *   如 `loading="lazy" referrerpolicy="no-referrer"`）。
 * @returns {string}
 */
export function lightboxImage({ id, src, alt, imgAttrs = '' }) {
  const safeId = String(id).replace(/[^A-Za-z0-9_-]/g, '_');
  const thumbId = `${safeId}-t`;
  const s = esc(src);
  const a = esc(alt);
  const extra = imgAttrs ? ` ${imgAttrs}` : '';
  const thumb = `<a class="lb-thumb" id="${thumbId}" href="#${safeId}"><img src="${s}" alt="${a}"${extra}></a>`;
  const overlay = `<div class="lb" id="${safeId}" role="dialog" aria-label="${a}">`
    + `<a class="lb-bg" href="#${thumbId}" aria-label="关闭" tabindex="-1"></a>`
    + `<img src="${s}" alt="${a}" loading="lazy"${extra.replace(/\sloading="[^"]*"/, '')}>`
    + `<a class="lb-orig" href="${s}" target="_blank" rel="noopener noreferrer">原图</a>`
    + `<a class="lb-x" href="#${thumbId}" aria-label="关闭" title="关闭">×</a>`
    + '</div>';
  return thumb + overlay;
}
