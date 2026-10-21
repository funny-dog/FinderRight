"""Run with: uv run --no-project python check.py."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).parent / "dist"

# 下载入口由 website/worker 优先提供官网镜像，页面不使用 GitHub 下载直链。
WORKER_DOWNLOADS = {
    "/download/FinderRight.dmg",
    "/download/FinderRight.dmg.sha256",
}


class PageCheck(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.fragments = []
        self.downloads = 0
        self.images = 0
        self.mocks = 0
        self.icons = set()
        self.translations = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate ID: {attrs['id']}"
            self.ids.add(attrs["id"])
        if "data-en" in attrs:
            assert attrs["data-en"], "Empty translation"
            self.translations += 1
        if tag == "img":
            assert "alt" in attrs, "Missing image alt"
            self.images += 1
            # 国内直连 Cloudflare 只有几 KB/s，页面图片须压缩后再引用。
            image = ROOT / urlsplit(attrs.get("src", "")).path
            if image.is_file():
                assert image.stat().st_size <= 100 * 1024, f"Image too large: {attrs['src']}"
        if "mock" in attrs.get("class", "").split():
            # 产品示意图用 HTML/CSS 绘制，读屏只能靠中英文描述
            assert attrs.get("role") == "img", "Mock needs role=img"
            assert attrs.get("aria-label") and attrs.get("data-en-label"), "Mock needs both labels"
            self.mocks += 1
        if tag == "use":
            self.icons.add(attrs.get("href", ""))
        if tag == "video":
            # 演示视频约 5MB，只在用户点击播放后加载。
            assert "autoplay" not in attrs and attrs.get("preload") == "none", "Video must not preload"
        if attrs.get("target") == "_blank":
            assert "noopener" in attrs.get("rel", "")
        for attribute in ("src", "href"):
            value = attrs.get(attribute, "")
            if value.startswith("#"):
                if value[1:]:
                    self.fragments.append(value[1:])
            elif value in WORKER_DOWNLOADS:
                # 镜像文件由发布同步脚本生成，干净检出时也允许这些下载入口。
                self.downloads += 1
            elif value and not urlsplit(value).scheme:
                assert (ROOT / urlsplit(value).path).is_file(), value
            elif "releases/latest/download/" in value:
                # 直连 GitHub 会绕开代理，且国内不可靠；只允许作为降级出口存在于 Worker 里。
                raise AssertionError(f"downlink should go through /download/: {value}")


if __name__ == "__main__":
    page = PageCheck()
    page.feed((ROOT / "index.html").read_text())
    assert set(page.fragments) <= page.ids, "Broken section link"
    # 顶栏、首屏、页尾三个下载按钮；安装指南不再重复下载入口
    assert page.downloads == 3, page.downloads
    # 首屏菜单加九张功能示意图
    assert page.mocks >= 10, page.mocks
    for icon in page.icons:
        sprite, _, symbol = icon.partition("#")
        assert f'id="{symbol}"' in (ROOT / sprite).read_text(), f"Missing icon: {icon}"
    assert page.translations >= 60
    print("OK: local assets, navigation, download links, alt text, mocks, icons, translations")
