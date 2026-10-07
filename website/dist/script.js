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
    ? 'A free, open-source macOS Finder utility. Create files, copy paths, open terminals, and cut and paste — right from the context menu.'
    : 'FinderRight 是开源免费的 macOS Finder 右键增强工具。新建文件、复制路径、打开终端、剪切粘贴，把顺手的操作放回右键菜单。';
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
