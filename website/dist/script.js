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
const translatedLabels = [...document.querySelectorAll('[data-en-label]')].map(element => ({
  element,
  chinese: element.getAttribute('aria-label'),
  english: element.dataset.enLabel,
}));

// 系统开启「减少动态效果」时不自动播放演示视频，改为显示控件由用户手动播放
const demoVideo = document.querySelector('.demo video');
if (demoVideo && matchMedia('(prefers-reduced-motion: reduce)').matches) {
  demoVideo.removeAttribute('autoplay');
  demoVideo.pause();
  demoVideo.controls = true;
}

const themeButton = document.querySelector('#theme');
const themeColor = document.querySelector('meta[name="theme-color"]');

// 主题已由 <head> 中的内联脚本写入 data-theme；这里只负责按钮文案与切换
function updateThemeButton() {
  const light = document.documentElement.dataset.theme === 'light';
  const english = locale === 'en';
  themeButton.setAttribute('aria-label', english
    ? (light ? 'Switch to dark theme' : 'Switch to light theme')
    : (light ? '切换到深色模式' : '切换到浅色模式'));
  themeColor.content = light ? '#e4ecf6' : '#0b1220';
}

languageButton.hidden = false;
copyButton.hidden = false;
themeButton.hidden = false;
updateThemeButton();
themeButton.addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
  document.documentElement.dataset.theme = next;
  // 隐私模式下 localStorage 可能不可用，失败时仅本次生效
  try { localStorage.setItem('theme', next); } catch {}
  updateThemeButton();
});
languageButton.addEventListener('click', () => {
  locale = locale === 'zh-CN' ? 'en' : 'zh-CN';
  const english = locale === 'en';
  document.documentElement.lang = locale;
  for (const entry of translatedElements) {
    // Only trusted, static copy authored in this document is rendered as HTML.
    entry.element.innerHTML = english ? entry.english : entry.chinese;
  }
  for (const entry of translatedImages) entry.element.alt = english ? entry.english : entry.chinese;
  for (const entry of translatedLabels) entry.element.setAttribute('aria-label', english ? entry.english : entry.chinese);
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
  updateThemeButton();
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
