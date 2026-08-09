// 取词纯函数（依赖 DOM Range 文本，可 jsdom/node 测）。content script 与 node 共用。
function expandWordWindow(textNode, offset, maxLen) {
  const text = (textNode && textNode.textContent) || '';
  return text.slice(offset, offset + maxLen);
}
function extractSentence(text, offset) {
  const enders = /[。．.!?！？\n]/;
  let start = offset, end = offset;
  while (start > 0 && !enders.test(text[start - 1])) start--;
  while (end < text.length && !enders.test(text[end])) end++;
  return text.slice(start, end + 1).trim();
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { expandWordWindow, extractSentence };
}
