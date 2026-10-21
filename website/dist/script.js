const languageButton = document.querySelector('#language');
const copyButtons = [...document.querySelectorAll('.copy-button')];
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

const themeButton = document.querySelector('#theme');
const themeColor = document.querySelector('meta[name="theme-color"]');
const prefersLight = window.matchMedia('(prefers-color-scheme: light)');
const systemTheme = () => (prefersLight.matches ? 'light' : 'dark');

// 只有与系统不同的手动选择才记住；记录与系统一致时清掉，恢复跟随系统（也清理旧版本留下的记录）
function rememberTheme(theme) {
  // 隐私模式下 localStorage 可能不可用，失败时仅本次生效
  try {
    if (theme === systemTheme()) localStorage.removeItem('theme');
    else localStorage.setItem('theme', theme);
  } catch {}
}
function savedTheme() {
  try { return localStorage.getItem('theme'); } catch { return null; }
}
rememberTheme(document.documentElement.dataset.theme);

// 主题已由 <head> 中的内联脚本写入 data-theme；这里只负责按钮文案与切换
function updateThemeButton() {
  const light = document.documentElement.dataset.theme === 'light';
  const english = locale === 'en';
  themeButton.setAttribute('aria-label', english
    ? (light ? 'Switch to dark theme' : 'Switch to light theme')
    : (light ? '切换到深色模式' : '切换到浅色模式'));
  themeColor.content = light ? '#f6f8fa' : '#0e1522';
}

languageButton.hidden = false;
for (const button of copyButtons) button.hidden = false;
themeButton.hidden = false;
updateThemeButton();
themeButton.addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
  document.documentElement.dataset.theme = next;
  rememberTheme(next);
  updateThemeButton();
});
// 没有手动选择时，系统切换深浅色，页面即时跟随
prefersLight.addEventListener('change', () => {
  if (savedTheme()) return;
  document.documentElement.dataset.theme = systemTheme();
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
  for (const status of document.querySelectorAll('.copy-status')) status.textContent = '';
  updateThemeButton();
});

// 每条命令各有复制按钮：复制同一行里的代码，结果写在这条命令下方
for (const button of copyButtons) {
  button.addEventListener('click', async () => {
    const block = button.closest('.cmd');
    const command = block.querySelector('code');
    const status = block.querySelector('.copy-status');
    for (const other of document.querySelectorAll('.copy-status')) other.textContent = '';
    try {
      await navigator.clipboard.writeText(command.textContent);
      status.textContent = locale === 'en' ? 'Copied' : '已复制';
    } catch {
      const range = document.createRange();
      range.selectNodeContents(command);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = locale === 'en' ? 'Selected. Press ⌘C to copy.' : '已选中，请按 ⌘C 复制';
    }
  });
}

// 功能卡片：点开后把对应示意图面板插到该卡片所在行的下方，同一时间只展开一张
const showcase = document.querySelector('[data-showcase]');
if (showcase) {
  const cards = [...showcase.querySelectorAll('.feature')];
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let openCard = null;

  const toggleOf = card => card.querySelector('.feature-toggle');
  const panelOf = card => document.getElementById(toggleOf(card).getAttribute('aria-controls'));

  function place(card) {
    const columns = getComputedStyle(showcase).gridTemplateColumns.split(' ').length;
    const index = cards.indexOf(card);
    const rowEnd = Math.min(cards.length - 1, Math.floor(index / columns) * columns + columns - 1);
    const panel = panelOf(card);
    cards[rowEnd].after(panel);
    panel.style.setProperty('--caret-x', `${((index % columns) + 0.5) / columns * 100}%`);
  }

  function close() {
    if (!openCard) return;
    panelOf(openCard).hidden = true;
    toggleOf(openCard).setAttribute('aria-expanded', 'false');
    openCard.classList.remove('is-open');
    openCard = null;
  }

  function open(card) {
    close();
    openCard = card;
    place(card);
    const panel = panelOf(card);
    panel.hidden = false;
    toggleOf(card).setAttribute('aria-expanded', 'true');
    card.classList.add('is-open');
    panel.scrollIntoView({ block: 'nearest', behavior: reduceMotion.matches ? 'auto' : 'smooth' });
  }

  showcase.addEventListener('click', event => {
    const toggle = event.target.closest('.feature-toggle');
    if (toggle) {
      const card = toggle.closest('.feature');
      card === openCard ? close() : open(card);
      return;
    }
    if (event.target.closest('.panel-close')) {
      const card = openCard;
      close();
      toggleOf(card).focus();
    }
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && openCard) {
      const card = openCard;
      close();
      toggleOf(card).focus();
    }
  });
  // 列数随窗口宽度变化时，面板跟着回到正确的行下方
  window.addEventListener('resize', () => { if (openCard) place(openCard); });
}
