#!/usr/bin/env python3
"""Builds Broski's website into one folder, ready for GitHub Pages:

- site/ as it is (files starting with "_" left out), with the repository and site links filled in;
- a page for each guide in docs/ and for the changelog, in the home page's own header and footer;
- what search engines and answer engines read: structured data, sitemap.xml, robots.txt, llms.txt,
  llms-full.txt, and a markdown copy of each guide.

It never names the repository itself: --site and --repo come from the Pages workflow, so a fork's site points
at the fork. Standard library only, Python 3.9 or later. A broken link, a page without a description or a guide
left out of DOCS is a problem, and the build fails on any problem.

  python3 scripts/site/build.py --out _site --site https://owner.github.io/broski --repo https://github.com/owner/broski
"""
from __future__ import annotations

import argparse
import datetime
import html as htmllib
import json
import math
import os
import plistlib
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from html.parser import HTMLParser
from itertools import dropwhile
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Doc:
    file: str  # in docs/
    group: str
    description: str  # what search results and llms.txt show: under 160 characters, true to the guide
    related: Tuple[str, ...] = ()  # the pages "Keep reading" suggests, by slug


# Every guide in docs/, in the order the site lists them. A guide missing here fails the build.
DOCS = [
    Doc("getting-started.md", "Use Broski",
        "Install Broski on a Mac and get through the first run: permissions, voice models, where your files live, "
        "and how to update or uninstall it.",
        related=("talking", "models")),
    Doc("talking.md", "Use Broski",
        "How to talk to Broski: the conversation, quick notes, Ask, help with what's on screen, where notes go, and "
        "the dashboard of every project.",
        related=("privacy", "trackers")),
    Doc("models.md", "Use Broski",
        "Choose the AI behind Broski for each role: Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek, "
        "Ollama, LM Studio or Apple's model.",
        related=("privacy", "troubleshooting")),
    Doc("privacy.md", "Use Broski",
        "What Broski sends to a model and what stays on your device: masked secrets, local-only projects, private "
        "mode, the encrypted vault and the mic.",
        related=("models", "talking")),
    Doc("iphone.md", "Use Broski",
        "Build and install the Broski iPhone app with a free Apple ID, sync it with your Mac through iCloud Drive, "
        "and set up its models and voice.",
        related=("getting-started", "privacy")),
    Doc("mcp.md", "Use Broski",
        "Connect Claude Code, Claude Desktop or any MCP client to Broski's MCP server to read your notes, project "
        "pages, decisions and trackers.",
        related=("trackers", "privacy")),
    Doc("trackers.md", "Use Broski",
        "How Broski finds your projects, reads each project's own tracker in place without writing to it, and how "
        "to onboard a project.",
        related=("mcp", "talking")),
    Doc("troubleshooting.md", "Use Broski",
        "Fix Broski when the mic hears nothing, recognition is wrong, a shortcut or model fails, or sync looks off, "
        "starting from the event log.",
        related=("getting-started", "models")),
    Doc("architecture.md", "Build on Broski",
        "How Broski is built: one Swift package with a shared core, the Mac and iPhone apps, the model gateway, "
        "stored formats and iCloud sync.",
        related=("testing", "privacy")),
    Doc("testing.md", "Build on Broski",
        "How Broski is tested: unit tests, self-tests, guardrail tests, the chat check, snapshots and CI, and the "
        "record that keeps untested code from shipping.",
        related=("releasing", "architecture")),
    Doc("releasing.md", "Build on Broski",
        "How a Broski release ships: version bump, full CI, a safe install with automatic rollback, the iPhone app, "
        "a tagged release and the website.",
        related=("testing", "getting-started")),
    Doc("SECURITY-REVIEW.md", "Build on Broski",
        "The checklist for an outside security review of Broski: how to set up, what to attack, the known items "
        "to verify first, and how to report.",
        related=("privacy", "architecture")),
]

# Every comparison in docs/compare/, shown at compare/<slug>/. Claims about another product carry their sources.
COMPARE = [
    Doc("compare/chatgpt.md", "Compare",
        "Broski vs the ChatGPT app: memory, voice, models, where your notes live, price and privacy, and when "
        "each one is the better choice.",
        related=("claude-desktop", "obsidian")),
    Doc("compare/claude-desktop.md", "Compare",
        "Broski vs the Claude desktop app: projects, memory, voice, models, MCP and where your data lives, and "
        "when each one is the better choice.",
        related=("chatgpt", "obsidian")),
    Doc("compare/obsidian.md", "Compare",
        "Broski vs Obsidian with AI plugins: plain markdown files, cloud and local models, voice and the "
        "conversation, and how the two work together.",
        related=("chatgpt", "claude-desktop")),
]

# When to recommend Broski and when not, for llms.txt: answer engines are asked "which app should I use for…".
WHEN = [
    "You want to talk or type to an AI about your own projects and have it remember past conversations, "
    "decisions and todos across days, on a Mac and an iPhone.",
    "You want what you keep to be plain markdown and JSON files in a folder you own (iCloud Drive, Dropbox, "
    "a Git repository), readable in any editor, Obsidian included.",
    "You want to choose or mix AI providers per kind of work, or keep a project on models running on your own "
    "device (Ollama, LM Studio, Apple's on-device model).",
    "You use Claude Code or another MCP client and want it to read your notes, decisions and project trackers.",
    "You want nothing saved unless you tap Save, and no account or server between you and your notes.",
]
NOT_WHEN = [
    "You use Windows, Linux or Android: Broski is a native Mac and iPhone app.",
    "You want a shared workspace for a team: Broski is for one person and their own folder.",
    "You want an AI service with nothing to set up: Broski's conversation needs a model you connect, a "
    "provider's key or a model on your device.",
    "You want image generation or a web browsing agent: Broski is about conversation and notes.",
]

# What Broski is, for llms.txt and the docs index. Keep it in step with the home page and the README.
ABOUT = ("Broski is a free, open-source companion app for Mac and iPhone that you talk to about your projects. "
         "Press a shortcut and talk or type: it remembers what you've told it, thinks things through with you, and "
         "saves decisions, todos and notes as plain markdown and JSON files you own, only when you tap Save. It works "
         "with the AI you choose: Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek, any OpenAI-compatible "
         "server, or a model on your device through Ollama, LM Studio or Apple's on-device model.")

# The repository's own pages a guide may link to with GitHub's relative form (../../../releases/latest).
GITHUB_ROUTES = {"releases", "issues", "pulls", "discussions", "security", "actions", "wiki", "tags", "commits"}

# Search engines' ownership checks, from the repository's variables (Settings › Secrets and variables › Actions).
VERIFY = {"GOOGLE_SITE_VERIFICATION": "google-site-verification", "BING_SITE_VERIFICATION": "msvalidate.01"}

# Crawlers for answer engines, named so the welcome is plain. Everyone else is welcome through "*".
ANSWER_ENGINES = ["GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User",
                  "PerplexityBot", "Perplexity-User", "Google-Extended", "Applebot-Extended", "Bingbot"]


def slug_of(file: str) -> str:
    return Path(file).stem.lower()


def esc(text: str) -> str:
    return htmllib.escape(text, quote=False).replace('"', "&quot;")


# MARK: Markdown (the parts the guides use)

@dataclass
class Page:
    html: str
    title: str
    summary: str
    headings: List[Tuple[int, str, str]]  # level, id, text
    problems: List[str]  # markdown the converter can't render faithfully


FENCE = re.compile(r"^( *)(?:(`{3,})([^`]*)|(~{3,})(.*))$")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
RULE = re.compile(r"^ {0,3}([-*_])(?:\s*\1){2,}\s*$")
BULLET = re.compile(r"^( *)([-*+])( +)(.*)$")
ORDERED = re.compile(r"^( *)(\d{1,9})([.)])( +)(.*)$")
TABLE_RULE = re.compile(r"^ *\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$")


def markdown(text: str, link: Callable[[str], str]) -> Page:
    """Renders markdown to HTML. `link` turns each link's target into the address to use."""
    return Markdown(link).render(text)


def plain(text: str) -> str:
    """Inline markdown as plain text."""
    text = re.sub(r"(`+)(.+?)\1", lambda m: m.group(2).strip(), text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<(https?://[^>\s]+)>", r"\1", text)
    text = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"\1", text)
    text = re.sub(r"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])", r"\1", text)
    text = re.sub(r"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)", r"\1", text)
    text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|<>])", r"\1", text)
    return re.sub(r"\s+", " ", text).strip()


def slugify(text: str) -> str:
    """GitHub's heading ids: lower case, punctuation dropped, spaces as hyphens."""
    return re.sub(r"[^\w\- ]", "", text.strip().lower()).replace(" ", "-")


def emphasis(text: str) -> str:
    text = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])", r"<em>\1</em>", text)
    return re.sub(r"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)", r"<em>\1</em>", text)


def split_row(row: str) -> List[str]:
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    return [cell.replace("\\|", "|") for cell in re.split(r"(?<!\\)\|", row)]


def fence_of(match) -> Tuple[str, str]:
    """A fence's marker (```) and its language, the info string's first word."""
    mark = match.group(2) or match.group(4)
    info = (match.group(3) if match.group(2) else match.group(5)) or ""
    words = info.split()
    return mark, re.sub(r"[^\w+#.-]", "", words[0]) if words else ""


def leading(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def has_inner_blank(body: List[str]) -> bool:
    """Whether an item's own blocks are separated by a blank line (a loose list), code blocks aside."""
    fence, seen, blank = None, False, False
    for line in body:
        match = FENCE.match(line)
        if fence:
            if match and fence_of(match)[0][0] == fence:
                fence = None
            continue
        if match:
            fence = fence_of(match)[0][0]
        if not line.strip():
            blank = seen
            continue
        if blank:
            return True
        seen = True
    return False


class Markdown:
    def __init__(self, link: Callable[[str], str]):
        self.link = link
        self.ids: Dict[str, int] = {}
        self.headings: List[Tuple[int, str, str]] = []
        self.paragraphs: List[str] = []
        self.problems: List[str] = []

    def render(self, text: str) -> Page:
        lines = text.replace("\r\n", "\n").replace("\t", "    ").split("\n")
        body = "\n".join(self.blocks(lines))
        title = self.headings[0][2] if self.headings and self.headings[0][0] == 1 else ""
        return Page(body + "\n", title, self.paragraphs[0] if self.paragraphs else "", self.headings, self.problems)

    def blocks(self, lines: List[str], tight: bool = False, depth: int = 0) -> List[str]:
        out: List[str] = []
        i, n = 0, len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            fence = FENCE.match(line)
            if fence:
                indent = len(fence.group(1))
                mark, lang = fence_of(fence)
                close = re.compile(r"^ *" + re.escape(mark[0]) + "{%d,}\\s*$" % len(mark))
                body = []
                i += 1
                while i < n and not close.match(lines[i]):
                    body.append(lines[i][min(indent, leading(lines[i])):])
                    i += 1
                if i >= n:
                    self.problems.append("a code block opened with %s%s is never closed" % (mark, lang))
                i += 1
                kind = ' class="language-%s"' % esc(lang) if lang else ""
                out.append("<pre><code%s>%s</code></pre>" % (kind, "".join(esc(row) + "\n" for row in body)))
                continue
            heading = HEADING.match(line)
            if heading:
                out.append(self.heading(len(heading.group(1)), heading.group(2)))
                i += 1
                continue
            if RULE.match(line):
                out.append("<hr>")
                i += 1
                continue
            if self.table_starts(lines, i):
                rows = []
                while i < n and lines[i].strip() and "|" in lines[i]:
                    rows.append(lines[i])
                    i += 1
                out.append(self.table(rows))
                continue
            if line.lstrip().startswith(">"):
                quoted = []
                while i < n and lines[i].lstrip().startswith(">"):
                    quoted.append(re.sub(r"^ *> ?", "", lines[i]))
                    i += 1
                out.append("<blockquote>\n" + "\n".join(self.blocks(quoted, depth=depth + 1)) + "\n</blockquote>")
                continue
            if BULLET.match(line) or ORDERED.match(line):
                html, i = self.list(lines, i, depth)
                out.append(html)
                continue
            paragraph = [line.strip()]
            i += 1
            while i < n and lines[i].strip() and not self.interrupts(lines, i):
                paragraph.append(lines[i].strip())
                i += 1
            text = " ".join(paragraph)
            if depth == 0:
                self.paragraphs.append(plain(text))
            out.append(self.inline(text) if tight else "<p>" + self.inline(text) + "</p>")
        return out

    def interrupts(self, lines: List[str], i: int) -> bool:
        line = lines[i]
        if FENCE.match(line) or HEADING.match(line) or RULE.match(line) or line.lstrip().startswith(">"):
            return True
        ordered = ORDERED.match(line)
        return bool(BULLET.match(line)) or bool(ordered and ordered.group(2) == "1") or self.table_starts(lines, i)

    @staticmethod
    def table_starts(lines: List[str], i: int) -> bool:
        if "|" not in lines[i] or i + 1 >= len(lines) or not TABLE_RULE.match(lines[i + 1]):
            return False
        return len(split_row(lines[i])) == len(split_row(lines[i + 1]))

    @staticmethod
    def item(line: str, ordered: Optional[bool]):
        if ordered is None:
            return ORDERED.match(line) or BULLET.match(line)
        return ORDERED.match(line) if ordered else BULLET.match(line)

    def list(self, lines: List[str], i: int, depth: int) -> Tuple[str, int]:
        n = len(lines)
        ordered = ORDERED.match(lines[i]) is not None
        first = self.item(lines[i], ordered)
        base = len(first.group(1))
        start = int(first.group(2)) if ordered else 1
        items: List[List[str]] = []
        loose = False
        while i < n:
            match = self.item(lines[i], ordered)
            if not match or len(match.group(1)) != base:
                break
            width, spaces, text = ((len(match.group(2)) + 1, len(match.group(4)), match.group(5)) if ordered
                                   else (1, len(match.group(3)), match.group(4)))
            indent = base + width + (spaces if spaces <= 4 else 1)
            body = [text]
            i += 1
            while i < n:
                line = lines[i]
                if not line.strip():
                    j = i
                    while j < n and not lines[j].strip():
                        j += 1
                    if j < n and leading(lines[j]) >= indent:
                        body.extend([""] * (j - i))
                        i = j
                        continue
                    break
                if leading(line) >= indent:
                    body.append(line[indent:])
                    i += 1
                    continue
                if self.item(line, None) or self.interrupts(lines, i):
                    break
                body.append(line.strip())  # a paragraph's lazy continuation
                i += 1
            items.append(body)
            if i < n and not lines[i].strip():
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                following = self.item(lines[j], ordered) if j < n else None
                if following and len(following.group(1)) == base:
                    loose = True
                    i = j
                    continue
                break
        loose = loose or any(has_inner_blank(body) for body in items)
        tag = "ol" if ordered else "ul"
        parts = ['<ol start="%d">' % start if ordered and start != 1 else "<%s>" % tag]
        for body in items:
            inner = "\n".join(self.blocks(body, tight=not loose, depth=depth + 1))
            parts.append("<li>" + inner + ("\n</li>" if loose else "</li>"))
        parts.append("</%s>" % tag)
        return "\n".join(parts), i

    def heading(self, level: int, text: str) -> str:
        label = plain(text)
        anchor = slugify(label)
        if anchor in self.ids:
            self.ids[anchor] += 1
            anchor = "%s-%d" % (anchor, self.ids[anchor])
        else:
            self.ids[anchor] = 0
        self.headings.append((level, anchor, label))
        return '<h%d id="%s">%s</h%d>' % (level, anchor, self.inline(text), level)

    def table(self, rows: List[str]) -> str:
        aligns = []
        for cell in split_row(rows[1]):
            cell = cell.strip()
            aligns.append("center" if cell.startswith(":") and cell.endswith(":") else
                          "right" if cell.endswith(":") else "left" if cell.startswith(":") else None)

        def row(line: str, tag: str) -> str:
            cells = []
            for k, cell in enumerate(split_row(line)):
                align = aligns[k] if k < len(aligns) else None
                kind = ' class="align-%s"' % align if align else ""  # not a style: the site's policy blocks those
                cells.append("<%s%s>%s</%s>" % (tag, kind, self.inline(cell.strip()), tag))
            return "<tr>" + "".join(cells) + "</tr>"

        html = ['<div class="table-wrap"><table>', "<thead>", row(rows[0], "th"), "</thead>"]
        if rows[2:]:
            html += ["<tbody>"] + [row(line, "td") for line in rows[2:]] + ["</tbody>"]
        return "\n".join(html + ["</table></div>"])

    def inline(self, text: str) -> str:
        kept: List[str] = []

        def keep(html: str) -> str:
            kept.append(html)
            return "\x00%d\x00" % (len(kept) - 1)

        text = re.sub(r"(`+)(.+?)\1", lambda m: keep("<code>" + esc(m.group(2).strip()) + "</code>"), text)
        text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|<>])", lambda m: keep(esc(m.group(1))), text)
        text = re.sub(r"!\[([^\]]*)\]\(([^)]*)\)", lambda m: keep(self.image(m.group(1), m.group(2))), text)
        text = re.sub(r"<(https?://[^\s>]+)>", lambda m: keep(self.anchor(m.group(1), esc(m.group(1)))), text)
        text = re.sub(r"\[([^\]]+)\]\(\s*([^)\s]+)(?:\s+\"[^\"]*\")?\s*\)",
                      lambda m: keep(self.anchor(m.group(2), emphasis(esc(m.group(1))))), text)
        text = re.sub(r"(?<![\w/\"'=])(https?://[^\s<>()\x00]+[^\s<>().,;:!?'\"\x00])",
                      lambda m: keep(self.anchor(m.group(1), esc(m.group(1)))), text)
        text = emphasis(esc(text))
        for _ in range(4):  # kept pieces can hold others: a link whose text is code
            text = re.sub(r"\x00(\d+)\x00", lambda m: kept[int(m.group(1))], text)
        return text

    def image(self, alt: str, src: str) -> str:
        self.problems.append("an image (%s) can't be shown on the site yet; describe it in words or add it to the builder" % src)
        return esc(alt)

    def anchor(self, url: str, inner: str) -> str:
        href = self.link(url)
        rel = ' rel="noopener"' if re.match(r"https?://", href) else ""
        return '<a href="%s"%s>%s</a>' % (esc(href), rel, inner)


# MARK: The site

def git_date(path: Path) -> str:
    """The day a file last changed: today when it has changes not yet committed, else its last commit."""
    today = datetime.date.today().isoformat()
    try:
        relative = str(path.relative_to(ROOT))
        changed = subprocess.run(["git", "status", "--porcelain", "--", relative], cwd=ROOT,
                                 capture_output=True, text=True, check=True).stdout.strip()
        if changed:
            return today
        day = subprocess.run(["git", "log", "-1", "--format=%cs", "--", relative], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.strip()
        return day or today
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return today


def newest_tag(tags: List[str]) -> Optional[str]:
    """The highest version among release tags (v0.11.3), without the v."""
    versions = [tuple(int(part) for part in tag[1:].split(".")) for tag in tags if re.fullmatch(r"v\d+(\.\d+)*", tag)]
    return ".".join(str(part) for part in max(versions)) if versions else None


def version() -> str:
    """The Mac version Download leads to: the newest release tag, or Info.plist's before the first release."""
    try:
        tags = subprocess.run(["git", "tag", "--list", "v*"], cwd=ROOT, capture_output=True, text=True,
                              check=True).stdout.split()
    except (subprocess.CalledProcessError, FileNotFoundError):
        tags = []
    tagged = newest_tag(tags)
    if tagged:
        return tagged
    with open(ROOT / "Resources" / "Info.plist", "rb") as file:
        return plistlib.load(file)["CFBundleShortVersionString"]


def phone_version() -> str:
    match = re.search(r"MARKETING_VERSION:\s*\"?([\d.]+)", (ROOT / "iOS" / "project.yml").read_text())
    return match.group(1) if match else ""


def released(mac_version: str) -> Optional[str]:
    """The release date of a Mac version, from its changelog heading."""
    match = re.search(r"^## Mac %s\b.*?(\d{4}-\d{2}-\d{2})\s*$" % re.escape(mac_version),
                      (ROOT / "CHANGELOG.md").read_text(), re.M)
    return match.group(1) if match else None


def reading_time(words: int) -> int:
    """Minutes to read, at 230 words a minute, rounded up."""
    return max(1, math.ceil(words / 230))


def common_questions(text: str) -> List[Tuple[str, str]]:
    """The questions under a guide's "## Common questions", with their answers, as markdown."""
    lines = text.replace("\r\n", "\n").split("\n")
    start = next((k for k, line in enumerate(lines) if re.match(r"^##\s+Common questions\s*$", line)), None)
    if start is None:
        return []
    found: List[Tuple[str, List[str]]] = []
    for line in lines[start + 1:]:
        if re.match(r"^#{1,2}\s", line):
            break
        heading = re.match(r"^###\s+(.*?)\s*$", line)
        if heading:
            found.append((heading.group(1), []))
        elif found:
            found[-1][1].append(line)
    answers = []
    for question, body in found:
        paragraphs = re.split(r"\n\s*\n", "\n".join(body).strip())
        answers.append((question, "\n\n".join(" ".join(p.split("\n")).strip() for p in paragraphs)))
    return answers


def human_date(day: str) -> str:
    date = datetime.date.fromisoformat(day)
    return "%d %s %d" % (date.day, date.strftime("%B"), date.year)


def clip(text: str, limit: int = 158) -> str:
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    cut = cut[: cut.rfind(" ")] if " " in cut else cut
    return cut.rstrip(",;:.") + "…"


def strip_tags(html: str) -> str:
    return re.sub(r"\s+", " ", htmllib.unescape(re.sub(r"<[^>]+>", "", html))).strip()


def ld_json(nodes: List[dict]) -> str:
    data = json.dumps({"@context": "https://schema.org", "@graph": nodes}, ensure_ascii=False, indent=1)
    return data.replace("</", "<\\/")


@dataclass
class Guide:
    doc: Doc
    slug: str
    page: Page
    date: str
    markdown: str  # with absolute links, for the markdown copy and llms-full.txt
    questions: List[Tuple[str, str]]  # its common questions, answers in markdown

    @property
    def path(self) -> str:
        return path_of(self.doc)


def path_of(doc: Doc) -> str:
    """Where a guide or comparison lives on the site."""
    return ("compare/%s/" if doc.file.startswith("compare/") else "docs/%s/") % slug_of(doc.file)


UNNUMBERED = {"Common questions", "Next", "Sources"}  # sections that close a page rather than step through it


PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'">
  <meta name="referrer" content="no-referrer">
  <title>{title}</title>
  <meta name="description" content="{description}">
  <meta name="robots" content="index, follow, max-image-preview:large">
  <meta name="color-scheme" content="light dark">
  <meta name="theme-color" content="#FFFDF8" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#141417" media="(prefers-color-scheme: dark)">
  <link rel="canonical" href="{url}">{alternate}
  <link rel="icon" type="image/png" sizes="64x64" href="{base}assets/icon-64.png">
  <link rel="apple-touch-icon" href="{base}assets/apple-touch-icon.png">
  <link rel="manifest" href="{base}site.webmanifest">
  <link rel="stylesheet" href="{base}styles.css">
  <meta property="og:type" content="{og_type}">
  <meta property="og:site_name" content="Broski">
  <meta property="og:title" content="{heading}">
  <meta property="og:description" content="{description}">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="__SITE__/assets/og.png">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="The Broski app icon next to the words: Broski, a companion you talk to about your projects.">
  <meta name="twitter:card" content="summary_large_image">
  <script type="application/ld+json">{ld}</script>
  <script src="{base}main.js" defer></script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
{sprite}
{header}

<main id="main" class="docs">
  <div class="wrap docs-grid">
    <article class="doc">
      <nav class="crumbs" aria-label="Breadcrumb"><ol>{crumbs}</ol></nav>
      <div class="prose">
{body}
      </div>{foot}
    </article>
    <nav class="docs-nav" aria-label="Guides">
{nav}
    </nav>{toc}
  </div>
</main>

{footer}
</body>
</html>
"""


class Site:
    def __init__(self, out: Path, site: str, repo: str, owner: Optional[str] = None,
                 verify: Optional[Dict[str, str]] = None):
        self.out = Path(out)
        self.site = site.rstrip("/")
        self.repo = repo.rstrip("/")
        self.owner = owner or self.repo.split("/")[-2]
        self.verify = verify or {}
        self.problems: List[str] = []
        self.indexed: List[Tuple[str, str]] = []  # (path from the site root, last changed), for the sitemap

    # Links

    @staticmethod
    def page_of(path: str) -> Optional[str]:
        """The site page for a file in the repository, if it has one."""
        if path == "CHANGELOG.md":
            return "changelog/"
        for doc in DOCS + COMPARE:
            if path == "docs/" + doc.file:
                return path_of(doc)
        return None

    def href(self, url: str, source: str, base: Optional[str]) -> str:
        """Where a link in a markdown file goes. `base` leads from the page to the site root ("../../"); None
        gives an absolute address, for the markdown copies."""
        if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("#"):
            return url
        target, _, fragment = url.partition("#")
        fragment = "#" + fragment if fragment else ""
        path = os.path.normpath(os.path.join(os.path.dirname(source), target))
        if path.startswith(".."):
            # Past the top of the repository, as GitHub reads it from a file's page (…/blob/main/docs/x.md):
            # ../../../releases/latest from a guide is the repository's releases. Anything else is broken there too.
            parts = path.split("/")
            ups = len(parts) - len(list(dropwhile(lambda part: part == "..", parts)))
            route = parts[ups:]
            if ups == 2 and route and route[0] in GITHUB_ROUTES:
                return self.repo + "/" + "/".join(route) + fragment
            self.problems.append("%s links to %s, which isn't a page of the repository" % (source, url))
            return self.repo
        page = self.page_of(path)
        if page:
            if base is None:
                return self.site + "/" + (page[:-1] + ".md" if page.startswith(("docs/", "compare/")) else page) + fragment
            return base + page + fragment
        if not (ROOT / path).exists():
            self.problems.append("%s links to %s, which isn't in the repository" % (source, url))
        kind = "tree" if (ROOT / path).is_dir() else "blob"
        return "%s/%s/main/%s%s" % (self.repo, kind, path, fragment)

    def absolute_markdown(self, text: str, source: str) -> str:
        return re.sub(r"\]\(([^)\s]+)\)", lambda m: "](%s)" % self.href(m.group(1), source, None), text)

    # People and things the structured data names

    def author(self) -> dict:
        return {"@type": "Person", "name": self.owner, "url": "https://github.com/" + self.owner}

    def publisher(self) -> dict:
        return {"@type": "Organization", "name": "Broski", "url": self.site + "/",
                "logo": {"@type": "ImageObject", "url": self.site + "/assets/icon-256.png"}}

    # Building

    def build(self) -> "Site":
        if self.out.exists():
            shutil.rmtree(self.out)
        shutil.copytree(ROOT / "site", self.out, ignore=shutil.ignore_patterns("_*", ".DS_Store"))
        home = (self.out / "index.html").read_text()
        self.sprite = re.search(r'<svg class="sprite".*?</svg>', home, re.S).group(0)
        self.header = re.search(r'<header class="site-header">.*?</header>', home, re.S).group(0)
        self.footer = re.search(r'<footer class="site-footer">.*?</footer>', home, re.S).group(0)
        undocumented = sorted({p.name for p in (ROOT / "docs").glob("*.md")} - {doc.file for doc in DOCS})
        for name in undocumented:
            self.problems.append("docs/%s isn't on the site: add it to DOCS in scripts/site/build.py" % name)
        compared = {"compare/" + p.name for p in (ROOT / "docs" / "compare").glob("*.md")}
        for name in sorted(compared - {doc.file for doc in COMPARE}):
            self.problems.append("docs/%s isn't on the site: add it to COMPARE in scripts/site/build.py" % name)
        for doc in COMPARE:
            if doc.file not in compared:
                self.problems.append("docs/%s is in COMPARE but isn't in the repository" % doc.file)
        guides = [self.guide(doc) for doc in DOCS]
        comparisons = [self.guide(doc) for doc in COMPARE if doc.file in compared]
        self.docs_index(guides, comparisons)
        self.changelog()
        self.home(home)
        self.faq(home, guides)
        self.indexed.insert(0, ("", git_date(ROOT / "site" / "index.html")))
        self.sitemap()
        self.robots()
        self.llms(guides, comparisons)
        self.fill()
        self.check()
        return self

    def guide(self, doc: Doc) -> Guide:
        source = "docs/" + doc.file
        text = (ROOT / source).read_text()
        base = "../../"
        page = markdown(text, link=lambda url: self.href(url, source, base))
        self.problems += ["%s: %s" % (source, problem) for problem in page.problems]
        slug = slug_of(doc.file)
        path = path_of(doc)
        date = git_date(ROOT / source)
        guide = Guide(doc, slug, page, date, self.absolute_markdown(text, source), common_questions(text))
        url = "%s/%s" % (self.site, path)
        description = doc.description
        if len(description) > 160:
            self.problems.append("%s: the description is over 160 characters" % source)
        if not page.title or not description:
            self.problems.append("%s needs a # title and a first paragraph" % source)
        compare = doc in COMPARE

        # The head: title, what the page is about, when it changed and how long it takes.
        body = page.html
        opening = re.match(r"(<h1 .*?</h1>)\n(?:<p>(.*?)</p>\n)?", body, re.S)
        if opening:
            body = body[opening.end():]
        minutes = reading_time(len(strip_tags(page.html).split()))
        head = ('<header class="doc-head">\n%s\n%s<p class="doc-meta"><span>Updated <time datetime="%s">%s</time></span>'
                '<span>%d min read</span></p>\n</header>\n'
                % (opening.group(1) if opening else "", '<p class="lede">%s</p>\n' % opening.group(2)
                   if opening and opening.group(2) else "", date, human_date(date), minutes))

        # Sections: numbered as steps through the page (guides only), and listed at the top and at the side.
        numbers = iter(range(1, 100))
        sections = []

        def number(match):
            anchor, label = match.group(1), strip_tags(match.group(2))
            n = "" if compare or label in UNNUMBERED else "%02d" % next(numbers)
            sections.append((anchor, label, n))
            return '<h2 id="%s"%s>%s</h2>' % (anchor, ' data-n="%s"' % n if n else "", match.group(2))

        body = re.sub(r'<h2 id="([^"]+)">(.*?)</h2>', number, body)
        toc, side = "", ""
        if len(sections) >= 3:
            items = "".join('<li><a href="#%s">%s%s</a></li>' % (anchor, '<span class="toc-n">%s</span>' % n if n else "",
                                                                  esc(label)) for anchor, label, n in sections)
            toc = ('<nav class="toc toc-inline" aria-label="In this page"><details><summary>In this page</summary>'
                   '<ol role="list">%s</ol></details></nav>\n' % items)
            side = ('\n    <nav class="toc toc-side" aria-label="In this page">\n      <p class="toc-title">In this page</p>'
                    '\n      <ol role="list">%s</ol>\n    </nav>' % items)

        # What to read next.
        everything = {slug_of(d.file): d for d in DOCS + COMPARE}
        cards = []
        for other in doc.related:
            if other not in everything or not (ROOT / "docs" / everything[other].file).exists():
                self.problems.append("%s: related page %s doesn't exist" % (source, other))
                continue
            target = everything[other]
            cards.append('<li><a href="%s/"><strong>%s</strong><span>%s</span></a></li>'
                         % (os.path.relpath(path_of(target), path), esc(self.title_of(target)), esc(target.description)))
        foot = ('\n      <footer class="doc-foot">\n        <p><a href="%s/edit/main/%s">Edit this page on GitHub</a> · '
                '<a href="../%s.md">Markdown</a></p>\n'
                '        <nav class="keep-reading" aria-label="Keep reading">\n          <h2>Keep reading</h2>\n'
                '          <ul class="doc-cards" role="list">%s</ul>\n        </nav>\n      </footer>'
                % (self.repo, source, slug, "".join(cards)))

        ld = [
            {"@type": "Article" if compare else "TechArticle", "@id": url + "#article", "headline": page.title,
             "description": description, "url": url, "dateModified": date, "inLanguage": "en",
             "image": self.site + "/assets/og.png", "wordCount": len(strip_tags(page.html).split()),
             "isPartOf": {"@id": self.site + "/#website"}, "about": {"@id": self.site + "/#app"},
             "author": self.author(), "publisher": self.publisher()},
            self.breadcrumbs([("Broski", ""), ("Docs", "docs/"), (page.title, path)]),
        ]
        if guide.questions:
            ld.append(self.faq_data(url + "#common-questions",
                                    [(plain(q), plain(a.replace("\n\n", " "))) for q, a in guide.questions]))
        self.write(path, title="%s · Broski%s" % (page.title, "" if compare else " docs"), heading=page.title,
                   description=description, body=head + toc + body, base=base,
                   og_type="article", ld=ld, crumbs=[("Home", ""), ("Docs", "docs/"), (page.title, None)],
                   current=path, foot=foot, alternate=path[:-1] + ".md", toc=side)
        (self.out / (path[:-1] + ".md")).write_text(guide.markdown)
        self.indexed.append((path, date))
        return guide

    @staticmethod
    def faq_data(anchor: str, questions: List[Tuple[str, str]]) -> dict:
        return {"@type": "FAQPage", "@id": anchor, "mainEntity": [
            {"@type": "Question", "name": question, "acceptedAnswer": {"@type": "Answer", "text": answer}}
            for question, answer in questions]}

    @staticmethod
    def title_of(doc: Doc) -> str:
        first = (ROOT / "docs" / doc.file).read_text().split("\n", 1)[0]
        return plain(first.lstrip("#"))

    def docs_index(self, guides: List[Guide], comparisons: List[Guide]):
        groups: Dict[str, List[Guide]] = {}
        for guide in guides:
            groups.setdefault(guide.doc.group, []).append(guide)
        body = ['<h1 id="docs">Broski docs</h1>',
                '<p class="lede">Guides to Broski on the Mac and iPhone: installing it, talking to it, choosing an '
                'AI model, privacy, Claude Code and MCP, and building on it.</p>']
        for group, members in groups.items():
            body.append('<h2 id="%s">%s</h2>' % (slugify(group), esc(group)))
            body.append('<ul class="doc-cards" role="list">')
            for guide in members:
                body.append('<li><a href="%s/"><strong>%s</strong><span>%s</span></a></li>'
                            % (guide.slug, esc(guide.page.title), esc(guide.doc.description)))
            body.append("</ul>")
        if comparisons:
            body.append('<h2 id="compare">Compared with other apps</h2>')
            body.append('<ul class="doc-cards" role="list">')
            for guide in comparisons:
                body.append('<li><a href="../%s"><strong>%s</strong><span>%s</span></a></li>'
                            % (guide.path, esc(guide.page.title), esc(guide.doc.description)))
            body.append("</ul>")
        body.append('<h2 id="project">Project</h2>\n<ul class="doc-cards" role="list"><li><a href="../faq/">'
                    '<strong>Questions</strong><span>Every common question about Broski, with a short answer and '
                    'the guide that goes further.</span></a></li><li><a href="../changelog/">'
                    '<strong>Changelog</strong><span>What changed in each release of the Mac and iPhone apps.</span>'
                    '</a></li></ul>')
        description = ("Guides to Broski, the open-source AI companion for Mac and iPhone: getting started, models, "
                       "privacy, the iPhone app, Claude Code and MCP.")
        url = self.site + "/docs/"
        ld = [
            {"@type": "CollectionPage", "@id": url, "url": url, "name": "Broski docs", "description": description,
             "inLanguage": "en", "isPartOf": {"@id": self.site + "/#website"},
             "hasPart": [{"@type": "TechArticle", "headline": g.page.title, "url": "%s%s/" % (url, g.slug)}
                         for g in guides + comparisons]},
            self.breadcrumbs([("Broski", ""), ("Docs", "docs/")]),
        ]
        self.write("docs/", title="Broski docs: guides for Mac and iPhone", heading="Broski docs",
                   description=description, body="\n".join(body), base="../", og_type="website", ld=ld,
                   crumbs=[("Home", ""), ("Docs", None)], current="docs/", foot="", alternate=None)
        self.indexed.append(("docs/", max(g.date for g in guides + comparisons)))

    def changelog(self):
        source = "CHANGELOG.md"
        base = "../"
        page = markdown((ROOT / source).read_text(), link=lambda url: self.href(url, source, base))
        self.problems += ["%s: %s" % (source, problem) for problem in page.problems]
        date = git_date(ROOT / source)
        description = "What changed in each release of Broski, the open-source AI companion for Mac and iPhone."
        url = self.site + "/changelog/"
        ld = [
            {"@type": "WebPage", "@id": url, "url": url, "name": "Broski changelog", "description": description,
             "dateModified": date, "inLanguage": "en", "isPartOf": {"@id": self.site + "/#website"},
             "about": {"@id": self.site + "/#app"}},
            self.breadcrumbs([("Broski", ""), ("Changelog", "changelog/")]),
        ]
        foot = ('\n      <footer class="doc-foot">\n        <p>Updated <time datetime="%s">%s</time>. '
                '<a href="%s/releases">Every release on GitHub</a></p>\n      </footer>'
                % (date, human_date(date), self.repo))
        self.write("changelog/", title="Changelog · Broski", heading="Broski changelog", description=description,
                   body=page.html, base=base, og_type="website", ld=ld, crumbs=[("Home", ""), ("Changelog", None)],
                   current="changelog/", foot=foot, alternate=None)
        self.indexed.append(("changelog/", date))

    def faq(self, home: str, guides: List[Guide]):
        """Every question in one place: the home page's, then each guide's, searchable when main.js runs."""
        base = "../"
        groups: List[Tuple[str, str, List[Tuple[str, str]], Optional[Guide]]] = []  # title, id, (question, answer html)
        asked = re.findall(r'<details[^>]*>\s*<summary>(.*?)</summary>\s*<div class="answer">(.*?)</div>\s*</details>',
                           home, re.S)
        groups.append(("About Broski", "about", [(q, rebase(a.strip(), base)) for q, a in asked], None))
        for guide in guides:
            if not guide.questions:
                continue
            source = "docs/" + guide.doc.file
            answers = []
            for question, answer in guide.questions:
                page = markdown(answer, link=lambda url: self.href(url, source, base))
                self.problems += ["%s: %s" % (source, problem) for problem in page.problems]
                answers.append((Markdown(lambda url: url).inline(question), page.html.strip()))
            groups.append((guide.page.title, guide.slug, answers, guide))

        body = ['<header class="doc-head">\n<h1 id="questions">Questions about Broski</h1>',
                '<p class="lede">Short answers about Broski on the Mac and iPhone: what it is, models, privacy, the '
                'iPhone app, Claude Code and fixing problems. Each group links to the guide that goes further.</p>',
                '</header>',
                '<p class="faq-search" data-faq-search hidden><label class="sr-only" for="faq-q">Search the questions'
                '</label><input id="faq-q" type="search" placeholder="Search the questions" autocomplete="off" '
                'spellcheck="false"></p>',
                '<p class="faq-none" data-faq-none hidden>No question matches that. Try fewer words, or '
                '<a href="__REPO__/issues">ask on GitHub</a>.</p>']
        data, seen = [], set()
        for title, anchor, answers, guide in groups:
            body.append('<section class="faq-group" data-faq-group aria-labelledby="%s">\n<h2 id="%s">%s</h2>\n<div class="faq">'
                        % (anchor, anchor, esc(title)))
            for question, answer in answers:
                qid = "q-" + slugify(strip_tags(question))
                if qid in seen:
                    self.problems.append("faq/ asks %r twice" % strip_tags(question))
                seen.add(qid)
                body.append('<details id="%s">\n<summary>%s</summary>\n<div class="answer">\n%s\n</div>\n</details>'
                            % (qid, question, answer))
                data.append((strip_tags(question), strip_tags(answer)))
            body.append("</div>")
            if guide:
                body.append('<p class="faq-more"><a href="../%s">Read %s</a></p>' % (guide.path, esc(guide.page.title)))
            body.append("</section>")
        description = ("Answers to common questions about Broski, the open-source AI companion for Mac and iPhone: "
                       "models, privacy, the iPhone app, Claude Code and fixes.")
        url = self.site + "/faq/"
        ld = [self.faq_data(url, data) | {"url": url, "name": "Questions about Broski", "inLanguage": "en",
                                           "isPartOf": {"@id": self.site + "/#website"}},
              self.breadcrumbs([("Broski", ""), ("Questions", "faq/")])]
        self.write("faq/", title="Questions about Broski: answers for Mac and iPhone", heading="Questions about Broski",
                   description=description, body="\n".join(body), base=base, og_type="website", ld=ld,
                   crumbs=[("Home", ""), ("Questions", None)], current="faq/", foot="", alternate=None)
        self.indexed.append(("faq/", max([git_date(ROOT / "site" / "index.html")] + [g.date for g in guides])))

    def breadcrumbs(self, trail: List[Tuple[str, str]]) -> dict:
        return {"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": k + 1, "name": name, "item": "%s/%s" % (self.site, path)}
            for k, (name, path) in enumerate(trail)]}

    def nav(self, base: str, current: str) -> str:
        groups: Dict[str, List[Doc]] = {}
        for doc in DOCS:
            groups.setdefault(doc.group, []).append(doc)
        for doc in COMPARE:
            if (ROOT / "docs" / doc.file).exists():
                groups.setdefault("Compare", []).append(doc)
        groups["Project"] = []
        lines = ['      <p class="docs-nav-title"><a href="%sdocs/"%s>All docs</a></p>'
                 % (base, ' aria-current="page"' if current == "docs/" else "")]
        for group, docs in groups.items():
            links = [(path_of(doc), self.title_of(doc)) for doc in docs]
            if group == "Project":
                links = [("faq/", "Questions"), ("changelog/", "Changelog")]
            lines.append("      <h2>%s</h2>\n      <ul role=\"list\">" % esc(group))
            for path, title in links:
                mark = ' aria-current="page"' if path == current else ""
                lines.append('        <li><a href="%s%s"%s>%s</a></li>' % (base, path, mark, esc(title)))
            lines.append("      </ul>")
        return "\n".join(lines)

    def write(self, path: str, title: str, heading: str, description: str, body: str, base: str, og_type: str,
              ld: List[dict], crumbs: List[Tuple[str, Optional[str]]], current: str, foot: str,
              alternate: Optional[str], toc: str = ""):
        trail = []
        for name, target in crumbs:
            if target is None:
                trail.append('<li aria-current="page">%s</li>' % esc(name))
            else:
                trail.append('<li><a href="%s%s">%s</a></li>' % (base, target, esc(name)))
        header = rebase(self.header, base)
        section = "faq/" if current == "faq/" else "docs/" if current.startswith(("docs/", "compare/")) else None
        if section:
            header = header.replace('href="%s%s"' % (base, section), 'href="%s%s" aria-current="page"' % (base, section), 1)
        html = PAGE.format(
            title=esc(title), heading=esc(heading), description=esc(description), url="%s/%s" % (self.site, path),
            alternate=('\n  <link rel="alternate" type="text/markdown" href="%s%s">' % (base, alternate)
                       if alternate else ""),
            base=base, og_type=og_type, ld=ld_json(ld), sprite=self.sprite, header=header,
            crumbs="".join(trail), body=body, foot=foot, nav=self.nav(base, current), toc=toc,
            footer=rebase(self.footer, base))
        target = self.out / path / "index.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(html)

    def home(self, html: str):
        description = re.search(r'<meta name="description" content="([^"]+)">', html).group(1)
        features = re.search(r'<section id="features".*?</section>', html, re.S)
        questions = re.findall(r'<details[^>]*>\s*<summary>(.*?)</summary>\s*<div class="answer">(.*?)</div>\s*</details>',
                               html, re.S)
        mac = version()
        day = released(mac)
        app = {
            "@type": "SoftwareApplication", "@id": self.site + "/#app", "name": "Broski",
            "description": htmllib.unescape(description), "url": self.site + "/",
            "applicationCategory": "ProductivityApplication", "applicationSubCategory": "AI assistant",
            "operatingSystem": "macOS 14 or later on Apple silicon; iOS 17 or later",
            "softwareVersion": mac, "downloadUrl": self.repo + "/releases/latest",
            "releaseNotes": self.site + "/changelog/",
            "license": "https://www.apache.org/licenses/LICENSE-2.0", "isAccessibleForFree": True,
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "image": self.site + "/assets/icon-1024.png",
            "screenshot": [self.site + "/assets/screens/light/%s.png" % name
                           for name in ("home", "home-riff", "dashboard-overview", "settings-models")
                           if (ROOT / ("site/assets/screens/light/%s.png" % name)).exists()],
            "featureList": [strip_tags(h) for h in re.findall(r"<h3[^>]*>(.*?)</h3>", features.group(0), re.S)]
            if features else [],
            "author": self.author(), "publisher": self.publisher(), "sameAs": [self.repo],
        }
        if day:
            app["dateModified"] = day
        nodes = [
            {"@type": "WebSite", "@id": self.site + "/#website", "url": self.site + "/", "name": "Broski",
             "description": htmllib.unescape(description), "inLanguage": "en", "publisher": self.publisher()},
            app,
            {"@type": "SoftwareSourceCode", "@id": self.site + "/#code", "name": "Broski",
             "codeRepository": self.repo, "programmingLanguage": "Swift", "runtimePlatform": "macOS, iOS",
             "license": "https://www.apache.org/licenses/LICENSE-2.0", "targetProduct": {"@id": self.site + "/#app"}},
            {"@type": "FAQPage", "@id": self.site + "/#faq", "mainEntity": [
                {"@type": "Question", "name": strip_tags(question),
                 "acceptedAnswer": {"@type": "Answer", "text": strip_tags(answer)}} for question, answer in questions]},
        ]
        extra = "".join('\n  <meta name="%s" content="%s">' % (name, esc(value)) for name, value in self.verify.items())
        extra += '\n  <script type="application/ld+json">%s</script>\n</head>' % ld_json(nodes)
        html = html.replace("__VERSION__", mac).replace("\n</head>", extra, 1)
        (self.out / "index.html").write_text(html)
        (self.out / "index.md").write_text(home_markdown(html, self.site, self.repo))

    def sitemap(self):
        rows = ["  <url><loc>%s/%s</loc><lastmod>%s</lastmod></url>" % (self.site, path, day)
                for path, day in self.indexed]
        (self.out / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
                                              '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                                              + "\n".join(rows) + "\n</urlset>\n")

    def robots(self):
        engines = "\n".join("User-agent: " + name for name in ANSWER_ENGINES)
        (self.out / "robots.txt").write_text(
            "# Everyone is welcome to read this site: search engines and answer engines alike.\n"
            "User-agent: *\nAllow: /\n\n%s\nAllow: /\n\nSitemap: %s/sitemap.xml\n" % (engines, self.site))

    def llms(self, guides: List[Guide], comparisons: List[Guide]):
        mac, phone = version(), phone_version()
        day = released(mac)
        lines = [
            "# Broski", "", "> " + ABOUT, "",
            "- Platforms: a menu-bar app for Mac (macOS 14 Sonoma or later, Apple silicon) and an app for iPhone "
            "(iOS 17 or later, built from source for now).",
            "- Price and license: free and open source under the Apache License 2.0. A cloud model is billed by its "
            "provider; a model on your device costs nothing.",
            "- Latest version: Mac %s%s%s." % (mac, " (%s)" % day if day else "", ", iPhone %s" % phone if phone else ""),
            "- Your data: plain files in a folder you pick (~/Broski, iCloud Drive, Dropbox or a Git repository). "
            "No account, no Broski server, no analytics.",
            "- Voice: Broski never sends audio anywhere itself. Bark and Whisper turn speech into text on the Mac, and "
            "Apple's recognizer runs on the device when the language supports it (otherwise Apple's speech service is used).",
            "- Privacy: projects marked local only use only models on your device; keys and tokens are masked before "
            "text reaches a model; nothing is saved as a note, todo or decision until you tap Save.",
            "- Claude Code and MCP: `Broski --mcp` is a Model Context Protocol server for Claude Code, Claude Desktop "
            "and other clients. It reads your notes, project pages, decisions and trackers, and writes only to "
            "trackers Broski keeps.",
            "- Download: %s/releases/latest" % self.repo,
            "- Website: %s/" % self.site,
        ]
        lines += ["", "## When to use Broski", ""] + ["- " + line for line in WHEN]
        lines += ["", "## When Broski isn't the right fit", ""] + ["- " + line for line in NOT_WHEN]
        groups: Dict[str, List[Guide]] = {}
        for guide in guides:
            groups.setdefault(guide.doc.group, []).append(guide)
        if comparisons:
            groups["Compared with other apps"] = comparisons
        for group, members in groups.items():
            lines += ["", "## " + group, ""]
            lines += ["- [%s](%s/%s.md): %s" % (g.page.title, self.site, g.path[:-1], g.doc.description) for g in members]
        lines += ["", "## Optional", "",
                  "- [The home page, as markdown](%s/index.md)" % self.site,
                  "- [Questions](%s/faq/): every common question with a short answer." % self.site,
                  "- [Changelog](%s/changelog/): what changed in each release." % self.site,
                  "- [Source code](%s): Swift. The Mac app, the iPhone app and the MCP server share one core." % self.repo,
                  "- [Every guide in one file](%s/llms-full.txt)" % self.site, ""]
        (self.out / "llms.txt").write_text("\n".join(lines))
        full = ["# Broski docs", "", "> " + ABOUT, ""]
        for guide in guides + comparisons:
            full += ["", "<!-- %s/%s -->" % (self.site, guide.path), "", guide.markdown.strip(), ""]
        (self.out / "llms-full.txt").write_text("\n".join(full))

    def fill(self):
        for path in self.out.rglob("*"):
            if path.suffix in {".html", ".txt", ".xml", ".md"}:
                text = path.read_text()
                filled = text.replace("__REPO__", self.repo).replace("__SITE__", self.site)
                if filled != text:
                    path.write_text(filled)

    # Checking

    def check(self):
        ids: Dict[Path, set] = {}
        pages = sorted(self.out.rglob("*.html"))
        for page in pages:
            ids[page] = set(re.findall(r'\bid="([^"]+)"', page.read_text()))
        for page in pages:
            html = page.read_text()
            name = str(page.relative_to(self.out))
            if re.search(r"__(REPO|SITE|VERSION)__", html):
                self.problems.append("%s still has a placeholder" % name)
            if name != "404.html":
                for what, pattern in (("a title", r"<title>[^<]+</title>"),
                                      ("a description", r'<meta name="description" content="[^"]+">'),
                                      ("a canonical address", r'<link rel="canonical" href="[^"]+">')):
                    if not re.search(pattern, html):
                        self.problems.append("%s has no %s" % (name, what))
                if len(re.findall(r"<h1[ >]", html)) != 1:
                    self.problems.append("%s needs exactly one <h1>" % name)
            prose = re.search(r'<div class="prose">(.*?)</article>', html, re.S)
            if prose:
                text = re.sub(r"<pre\b.*?</pre>|<code\b.*?</code>", "", prose.group(1), flags=re.S)
                text = htmllib.unescape(re.sub(r"<[^>]+>", "", text))
                left = re.search(r"\]\(|!\[|```|~~~|^\s*\|?\s*:?-{3,}:?\s*\||\*\*\S", text, re.M)
                if left:
                    self.problems.append("%s has markdown left over: %r" % (name, text[max(0, left.start() - 30):left.end() + 30]))
            for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
                try:
                    json.loads(block)
                except ValueError as error:
                    self.problems.append("%s has structured data that isn't JSON: %s" % (name, error))
            for attribute, url in re.findall(r'\b(href|src|srcset|content)="([^"]+)"', html):
                url = htmllib.unescape(url)
                if attribute == "content" and not url.startswith(self.site):
                    continue  # a meta value, not a link
                self.check_link(name, url, ids)

    def check_link(self, name: str, url: str, ids: Dict[Path, set]):
        """A link from page `name` (a path in the built site) must reach a file there, and its #fragment an id."""
        if url == self.site or url.startswith(self.site + "/"):
            address = url[len(self.site) + 1:]
            path, _, fragment = address.partition("#")
        elif re.match(r"^([a-z][a-z0-9+.-]*:|//)", url, re.I):
            return  # another site
        else:
            relative, _, fragment = url.partition("#")
            path = os.path.normpath(os.path.join(os.path.dirname(name), relative)) if relative else name
        file = self.out / path
        if path in ("", ".") or path.endswith("/") or file.is_dir():
            file = file / "index.html"
        if path.startswith("..") or not file.is_file():
            self.problems.append("%s links to %s, which isn't on the site" % (name, url))
            return
        if fragment and fragment != "top" and file.suffix == ".html" and fragment not in ids.get(file, set()):
            self.problems.append("%s links to %s, but that page has no #%s" % (name, url, fragment))


class HomeMarkdown(HTMLParser):
    """The home page's main content as markdown, for answer engines: what a screen reader would read, so a
    shortcut reads "Option Shift B" and decorations are left out."""

    BLOCKS = {"h1", "h2", "h3", "p", "li", "summary", "figcaption", "dt", "dd"}
    VOID = {"img", "br", "hr", "input", "meta", "link", "source", "wbr"}

    def __init__(self, site: str):
        super().__init__(convert_charrefs=True)
        self.site = site
        self.blocks: List[str] = []
        self.text = ""
        self.skip = 0
        self.links: List[Tuple[str, str]] = []  # href, the text before the link
        self.term = ""

    def address(self, href: str) -> str:
        if re.match(r"^[a-z][a-z0-9+.-]*:|^__", href):
            return href
        return self.site + "/" + href

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if self.skip:
            self.skip += tag not in self.VOID
            return
        classes = (attributes.get("class") or "").split()
        if (attributes.get("aria-hidden") == "true" or tag in {"svg", "picture", "script", "style"}
                or {"terminal", "app-badge"} & set(classes)):
            self.skip = 1
            return
        if attributes.get("role") == "img" and attributes.get("aria-label"):
            self.blocks.append(attributes["aria-label"])
            self.skip = 1
        elif tag in self.BLOCKS:
            self.text = ""
        elif tag == "a":
            self.links.append((attributes.get("href", ""), self.text))
            self.text = ""
        elif tag in {"strong", "b"}:
            self.text += "**"
        elif tag == "code":
            self.text += "`"

    def handle_startendtag(self, tag, attrs):
        if not self.skip and dict(attrs).get("role") == "img" and dict(attrs).get("aria-label"):
            self.blocks.append(dict(attrs)["aria-label"])

    def handle_endtag(self, tag):
        if self.skip:
            self.skip -= tag not in self.VOID
            return
        text = re.sub(r"\s+", " ", self.text).strip()
        if tag == "a" and self.links:
            href, before = self.links.pop()
            self.text = before + ("[%s](%s)" % (text, self.address(href)) if text else "")
        elif tag in {"strong", "b"}:
            self.text = self.text.rstrip() + "**"
        elif tag == "code":
            self.text += "`"
        elif tag in {"h1", "h2", "h3"} and text:
            self.blocks.append("#" * int(tag[1]) + " " + text)
            self.text = ""
        elif tag == "summary" and text:
            self.blocks.append("### " + text)
            self.text = ""
        elif tag == "dt":
            self.term, self.text = text, ""
        elif tag == "dd" and text:
            self.blocks.append("- **%s**: %s" % (self.term, text))
            self.text = ""
        elif tag == "li" and text:
            self.blocks.append("- " + text)
            self.text = ""
        elif tag in {"p", "figcaption"} and text:
            self.blocks.append(text)
            self.text = ""

    def handle_data(self, data):
        if not self.skip:
            self.text += data
        elif data.strip() == "·":  # a separator hidden from screen readers still separates here
            self.text += " · "


def home_markdown(html: str, site: str, repo: str) -> str:
    parser = HomeMarkdown(site)
    parser.feed(re.search(r"<main\b.*?</main>", html, re.S).group(0))
    out = []
    for block in parser.blocks:
        # Keep a list together; separate everything else with a blank line.
        joined = bool(out) and block.startswith("- ") and out[-1].lstrip("\n").startswith("- ")
        out.append(("" if joined else "\n") + block)
    tail = ("\n\n---\n\n[Docs](%s/docs/) · [Questions](%s/faq/) · [Download](%s/releases/latest) · [Source](%s) · "
            "[llms.txt](%s/llms.txt)\n" % (site, site, repo, repo, site))
    return "\n".join(out).strip() + tail


def rebase(fragment: str, base: str) -> str:
    """The home page's header or footer as seen from a page `base` away from the site root."""
    if not base:
        return fragment

    def tag(match):
        return re.sub(r'\b(href|src)="(?![a-z][a-z0-9+.-]*:|__|/)([^"]*)"',
                      lambda a: '%s="%s%s"' % (a.group(1), base, a.group(2)), match.group(0))

    return re.sub(r"<(?:a|img)\b[^>]*>", tag, fragment)


def build(out: Path, site: str, repo: str, owner: Optional[str] = None, verify: Optional[Dict[str, str]] = None) -> Site:
    return Site(out, site, repo, owner, verify).build()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Build Broski's website.")
    parser.add_argument("--out", required=True, help="the folder to build into (it's replaced)")
    parser.add_argument("--site", required=True, help="the site's address, such as https://owner.github.io/broski")
    parser.add_argument("--repo", required=True, help="the repository's address, such as https://github.com/owner/broski")
    parser.add_argument("--owner", help="who the structured data names as the author (default: the repository's owner)")
    args = parser.parse_args(argv)
    verify = {name: os.environ[variable] for variable, name in VERIFY.items() if os.environ.get(variable)}
    site = build(Path(args.out), args.site, args.repo, args.owner, verify)
    if site.problems:
        print("The site has problems:", file=sys.stderr)
        for problem in site.problems:
            print("  " + problem, file=sys.stderr)
        return 1
    print("Built %d pages into %s" % (len(site.indexed) + 1, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
