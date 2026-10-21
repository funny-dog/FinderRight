"""Run with: uv run --no-project python check.py."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).parent / "dist"

# 下载入口由 website/worker 代理到 GitHub，页面里不再出现 github.com 下载直链。
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
        self.checksums = 0
        self.images = 0
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
        if attrs.get("target") == "_blank":
            assert "noopener" in attrs.get("rel", "")
        for attribute in ("src", "href"):
            value = attrs.get(attribute, "")
            if value.startswith("#"):
                if value[1:]:
                    self.fragments.append(value[1:])
            elif value in WORKER_DOWNLOADS:
                # 这些路径由 Worker 提供，磁盘上没有对应文件。
                if value.endswith(".sha256"):
                    self.checksums += 1
                else:
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
    assert page.downloads == 4, page.downloads
    assert page.checksums == 1, page.checksums
    assert page.images >= 6
    assert page.translations >= 60
    print("OK: local assets, navigation, download links, checksum, alt text, translations")
