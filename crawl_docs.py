#!/usr/bin/env python3
"""
Project Sylvanas Documentation Crawler
=======================================
Crawls https://docs.project-sylvanas.net/ automatically by discovering all
pages from the sidebar navigation and in-page links.

Usage:
    python crawl_docs.py              # auto-discover and crawl all pages
    python crawl_docs.py --dry-run    # discover pages but don't download
    python crawl_docs.py --single URL # crawl a single URL for testing

Output goes to documentation/ (existing crawled_*.md files are overwritten).
"""

import os
import re
import sys
import time
import argparse
from collections import deque

# Force UTF-8 output on Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import requests
from bs4 import BeautifulSoup, Tag
from markdownify import markdownify as md
from urllib.parse import urljoin, urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_URL = "https://docs.project-sylvanas.net"
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "documentation")
REQUEST_DELAY = 1.0  # seconds between requests (be polite)
TIMEOUT = 30         # request timeout in seconds

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) SylvanasCrawler/1.0",
    "Accept": "text/html,application/xhtml+xml",
}

# Seed pages — the crawler starts here and follows all internal links.
SEED_PATHS = [
    "",                 # homepage
    "dev",              # developer docs root
    "examples",         # examples index
    "getting-started/intro",
    "modules/menu",
    "plugins/universal-items",
]

# Paths to skip (index pages with no real content, or non-doc pages)
SKIP_PATHS = {
    "search",
    "blog",
    "tags",
}

# File extensions to ignore when discovering links
SKIP_EXTENSIONS = re.compile(
    r"\.(png|jpg|jpeg|gif|svg|webp|ico|css|js|json|xml|zip|tar|gz|pdf|mp4|woff2?)$",
    re.I,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def path_to_filename(path: str) -> str:
    """Convert a URL path like 'dev/api/core' to 'crawled_dev_api_core.md'."""
    if not path or path == "/":
        return "crawled_index.md"
    slug = path.strip("/").replace("/", "_")
    slug = re.sub(r"[^a-zA-Z0-9_\-]", "_", slug)
    return f"crawled_{slug}.md"


def extract_page_title(soup: BeautifulSoup) -> str:
    """Extract the page title from <h1> or <title>."""
    h1 = soup.select_one("article h1, main h1, h1")
    if h1:
        return h1.get_text(strip=True)
    title = soup.find("title")
    if title:
        text = title.get_text(strip=True)
        # Strip " | Project Sylvanas" suffix
        return re.sub(r"\s*\|.*$", "", text)
    return ""


def extract_main_content(soup: BeautifulSoup) -> Tag | None:
    """Find the main article/content area, skipping nav/sidebar/footer."""
    for selector in ["article", "main", '[class*="docMainContainer"]',
                     '[class*="markdown"]', '[role="main"]']:
        el = soup.select_one(selector)
        if el:
            return el
    return None


def clean_html(content_tag: Tag) -> str:
    """Remove noisy elements from the content before markdown conversion."""
    for selector in [
        '[class*="pagination-nav"]',
        '[class*="table-of-contents"]',
        '[class*="tocCollapsible"]',
        'a[class*="edit-page"]',
        'a[href*="edit"]',
        'footer',
        'nav',
        '[class*="breadcrumbs"]',
        '[class*="theme-doc-footer"]',
        '[class*="admonition-icon"]',
    ]:
        for el in content_tag.select(selector):
            el.decompose()

    for svg in content_tag.find_all("svg"):
        svg.decompose()

    return str(content_tag)


def html_to_markdown(html: str) -> str:
    """Convert cleaned HTML to markdown and tidy up."""
    text = md(
        html,
        heading_style="ATX",
        code_language_callback=lambda el: _guess_lang(el),
        strip=["img"],
        bullets="-",
    )

    # Remove Docusaurus anchor links like [X](#section "Direct link to ...")
    text = re.sub(r'\[.{1,3}\]\(#[^)]*"Direct link to[^"]*"\)', '', text)

    # Remove stray single-char unicode garbage at end of heading lines
    text = re.sub(r'(\#{1,6}\s+.+?)\s+[\u00c0-\u024f\u2000-\u27ff\ufffd]{1,3}\s*$',
                  r'\1', text, flags=re.MULTILINE)

    # Remove stray emoji-like markers from headings
    text = re.sub(r'\s*[\U0001f000-\U0001ffff\u00f0-\u00ff]+\s*$', '', text, flags=re.MULTILINE)

    # Collapse excessive blank lines
    text = re.sub(r"\n{4,}", "\n\n\n", text)

    # Remove trailing whitespace per line
    text = "\n".join(line.rstrip() for line in text.splitlines())

    return text.strip()


def _guess_lang(el):
    """Try to guess code language from Docusaurus class names."""
    classes = el.get("class", []) if hasattr(el, "get") else []
    for cls in classes:
        if cls.startswith("language-"):
            return cls.replace("language-", "")
    return ""


def extract_links(soup: BeautifulSoup, current_url: str) -> list[str]:
    """Extract all internal doc links from a page (sidebar + content)."""
    found = set()
    for a in soup.find_all("a", href=True):
        href = a["href"]
        full = urljoin(current_url, href)
        parsed = urlparse(full)

        # Only same host
        if parsed.hostname and "docs.project-sylvanas.net" not in parsed.hostname:
            continue

        # Strip fragment and query
        path = parsed.path.strip("/")

        if not path:
            continue
        if SKIP_EXTENSIONS.search(path):
            continue
        if path in SKIP_PATHS:
            continue

        found.add(path)
    return list(found)


# ---------------------------------------------------------------------------
# Discovery: BFS crawl to find all pages
# ---------------------------------------------------------------------------

def discover_all_pages(session: requests.Session) -> dict[str, str]:
    """BFS from seed pages, following all internal links.
    Returns {path: title} for every page found."""

    visited: set[str] = set()
    queue: deque[str] = deque()
    pages: dict[str, str] = {}   # path -> title

    # Seed the queue
    for seed in SEED_PATHS:
        seed = seed.strip("/")
        queue.append(seed)

    print(f"Discovering pages (starting from {len(SEED_PATHS)} seeds)...\n")

    while queue:
        path = queue.popleft()
        if path in visited:
            continue
        visited.add(path)

        url = f"{BASE_URL}/{path}" if path else BASE_URL
        try:
            resp = session.get(url, headers=HEADERS, timeout=TIMEOUT)
            if resp.status_code == 404:
                print(f"  [404] /{path}")
                continue
            resp.raise_for_status()
        except requests.RequestException as e:
            print(f"  [ERR] /{path}: {e}")
            continue

        soup = BeautifulSoup(resp.text, "html.parser")

        # Only keep pages that have real content
        content = extract_main_content(soup)
        if not content:
            print(f"  [SKIP] /{path} (no content)")
            continue

        title = extract_page_title(soup) or path
        pages[path] = title
        print(f"  [FOUND] /{path:50s} → {title}")

        # Discover new links
        for link in extract_links(soup, url):
            if link not in visited:
                queue.append(link)

        time.sleep(REQUEST_DELAY * 0.5)  # lighter delay during discovery

    print(f"\nDiscovery complete: {len(pages)} pages found.\n")
    return pages


# ---------------------------------------------------------------------------
# Crawl logic
# ---------------------------------------------------------------------------

def crawl_page(session: requests.Session, path: str, label: str) -> str:
    """Fetch a single page, return markdown content."""
    url = f"{BASE_URL}/{path}" if path else BASE_URL
    resp = session.get(url, headers=HEADERS, timeout=TIMEOUT)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")
    content = extract_main_content(soup)

    if not content:
        return ""

    cleaned = clean_html(content)
    markdown = html_to_markdown(cleaned)

    header = f"# {label}\n\n> Source: {url}\n\n"
    return header + markdown


def save_page(path: str, content: str) -> str:
    """Write markdown to documentation/ folder."""
    filename = path_to_filename(path)
    filepath = os.path.join(OUTPUT_DIR, filename)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    return filepath


def run_crawl(pages: dict[str, str], dry_run: bool = False):
    """Download and save all pages."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if dry_run:
        print(f"DRY RUN — {len(pages)} pages would be crawled:\n")
        for path, label in sorted(pages.items()):
            url = f"{BASE_URL}/{path}"
            filename = path_to_filename(path)
            print(f"  {filename:55s} ← {url}")
        return

    session = requests.Session()
    total = len(pages)
    success = 0
    failed = []

    print(f"Crawling {total} pages from {BASE_URL} ...\n")

    for i, (path, label) in enumerate(pages.items(), 1):
        url = f"{BASE_URL}/{path}"
        print(f"[{i:3d}/{total}] {label:45s} {url}")

        try:
            content = crawl_page(session, path, label)
            if content:
                filepath = save_page(path, content)
                size_kb = len(content.encode("utf-8")) / 1024
                print(f"         → {os.path.basename(filepath)} ({size_kb:.1f} KB)")
                success += 1
            else:
                print(f"         → SKIPPED (no content)")
                failed.append((path, "no content"))

        except requests.RequestException as e:
            print(f"         → FAILED: {e}")
            failed.append((path, str(e)))

        if i < total:
            time.sleep(REQUEST_DELAY)

    # ── Summary ──────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"DONE: {success}/{total} pages crawled successfully")
    print(f"Output: {OUTPUT_DIR}/")

    if failed:
        print(f"\nFailed ({len(failed)}):")
        for path, reason in failed:
            print(f"  - {path}: {reason}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Crawl Project Sylvanas docs")
    parser.add_argument("--dry-run", action="store_true",
                        help="Discover pages but don't download content")
    parser.add_argument("--single", type=str, default=None,
                        help="Crawl a single path (e.g. 'dev/api/core')")
    parser.add_argument("--delay", type=float, default=None,
                        help="Delay between requests in seconds (default: 1.0)")
    args = parser.parse_args()

    global REQUEST_DELAY
    if args.delay is not None:
        REQUEST_DELAY = args.delay

    if args.single:
        # Single-page mode: no discovery
        path = args.single.strip("/")
        pages = {path: path}
        run_crawl(pages, dry_run=args.dry_run)
    else:
        # Auto-discover all pages via BFS
        session = requests.Session()
        pages = discover_all_pages(session)

        if not pages:
            print("No pages discovered. Check your network or the seed URLs.")
            sys.exit(1)

        run_crawl(pages, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
