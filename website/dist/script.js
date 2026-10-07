const languageButton = document.querySelector('#language');
const copyButton = document.querySelector('#copy-command');
const copyStatus = document.querySelector('#copy-status');
let locale = 'zh-CN';

const translatedElements = [...document.querySelectorAll('[data-en]')].map(element => ({
  element,
  chinese: element.innerHTML,
  english: element.dataset.en,
}));
const translatedImages = [...document.querySelectorAll('[data-en-alt]')].map(element => ({
  element,
  chinese: element.alt,
  english: element.dataset.enAlt,
}));

languageButton.hidden = false;
copyButton.hidden = false;
languageButton.addEventListener('click', () => {
  locale = locale === 'zh-CN' ? 'en' : 'zh-CN';
  const english = locale === 'en';
  document.documentElement.lang = locale;
  for (const entry of translatedElements) {
    // Only trusted, static copy authored in this document is rendered as HTML.
    entry.element.innerHTML = english ? entry.english : entry.chinese;
  }
  for (const entry of translatedImages) entry.element.alt = english ? entry.english : entry.chinese;
  languageButton.innerHTML = `${english ? '中文' : 'EN'} <span aria-hidden="true">↔</span>`;
  languageButton.setAttribute('aria-label', english ? '切换到中文' : 'Switch to English');
  document.title = english ? 'FinderRight — A better right-click' : 'FinderRight — 让 Finder 更顺手';
  const description = english
    ? 'Create files, open a terminal, and cut & paste from Finder’s right-click menu. Free and open source. File operations stay on your Mac.'
    : '给 Mac 的 Finder 加上右键新建文件、打开终端和剪切粘贴——免费开源，文件操作在本地完成。';
  document.querySelector('meta[name="description"]').content = description;
  document.querySelector('meta[property="og:title"]').content = document.title;
  document.querySelector('meta[property="og:description"]').content = description;
  copyStatus.textContent = '';
});

copyButton.addEventListener('click', async () => {
  const command = document.querySelector('#launch-command');
  try {
    await navigator.clipboard.writeText(command.textContent);
    copyStatus.textContent = locale === 'en' ? 'Copied' : '已复制';
  } catch {
    const range = document.createRange();
    range.selectNodeContents(command);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    copyStatus.textContent = locale === 'en' ? 'Selected. Press ⌘C to copy.' : '已选中，请按 ⌘C 复制';
  }
});
