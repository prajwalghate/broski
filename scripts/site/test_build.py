#!/usr/bin/env python3
"""Tests for the site builder. Run: python3 scripts/site/test_build.py (scripts/site.sh runs them first)."""
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build  # noqa: E402

SITE = "https://example.test/broski"
REPO = "https://github.com/someone/broski"


def md(text):
    return build.markdown(text, link=lambda url: url).html


class MarkdownTests(unittest.TestCase):
    def test_the_first_heading_is_the_title_and_headings_get_github_ids(self):
        page = build.markdown("# Getting started\n\nIntro.\n\n## Install from a release\n\n## What's new?\n",
                              link=lambda url: url)
        self.assertEqual(page.title, "Getting started")
        self.assertIn('<h2 id="install-from-a-release">', page.html)
        self.assertIn('<h2 id="whats-new">', page.html)
        self.assertEqual([h[1] for h in page.headings], ["getting-started", "install-from-a-release", "whats-new"])

    def test_a_repeated_heading_gets_a_numbered_id(self):
        html = md("## Fixed\n\n## Fixed\n")
        self.assertIn('id="fixed"', html)
        self.assertIn('id="fixed-1"', html)

    def test_the_summary_is_the_first_paragraph_as_plain_text(self):
        page = build.markdown("# Models\n\nBroski isn't tied to **one** AI company. See [roles](#roles).\n\nMore.",
                              link=lambda url: url)
        self.assertEqual(page.summary, "Broski isn't tied to one AI company. See roles.")

    def test_angle_brackets_in_prose_are_shown_not_swallowed(self):
        self.assertIn("No sound came from &lt;mic&gt;", md('No sound came from <mic>'))

    def test_inline_code_keeps_its_characters(self):
        html = md("Run `a **b** <c> d_e_f` now.")
        self.assertIn("<code>a **b** &lt;c&gt; d_e_f</code>", html)
        self.assertNotIn("<strong>", html)

    def test_underscores_inside_words_are_not_emphasis(self):
        html = md("Set BROSKI_BUNDLE_ID and _this_ one.")
        self.assertIn("BROSKI_BUNDLE_ID", html)
        self.assertIn("<em>this</em>", html)

    def test_bold_italic_and_links(self):
        html = md("**Open Anyway**, *once*, and [the guide](models.md#roles).")
        self.assertIn("<strong>Open Anyway</strong>", html)
        self.assertIn("<em>once</em>", html)
        self.assertIn('<a href="models.md#roles">the guide</a>', html)

    def test_link_text_can_hold_code(self):
        self.assertIn('<a href="x.md"><code>Broski --mcp</code></a>', md("[`Broski --mcp`](x.md)"))

    def test_external_links_and_bare_urls(self):
        html = md("Get one at [platform.openai.com](https://platform.openai.com/api-keys) or https://example.com/a.")
        self.assertIn('<a href="https://platform.openai.com/api-keys" rel="noopener">platform.openai.com</a>', html)
        self.assertIn('<a href="https://example.com/a" rel="noopener">https://example.com/a</a>.', html)

    def test_a_tight_list_with_a_nested_list(self):
        html = md("- one\n- two\n  - two a\n  - two b\n- three\n")
        self.assertEqual(html.count("<ul>"), 2)
        self.assertIn("<li>two\n<ul>\n<li>two a</li>", html)
        self.assertNotIn("<p>", html)

    def test_an_ordered_list_keeps_counting_across_an_indented_code_block(self):
        text = ("1. Download it.\n"
                "2. Check it:\n\n"
                "   ```bash\n"
                "   shasum -a 256 ~/Downloads/Broski-*.zip\n"
                "   ```\n\n"
                "3. Unzip it.\n"
                "4. If macOS warns you:\n"
                "   - **macOS 15:** Open Anyway.\n"
                "   - **macOS 14:** right-click.\n\n"
                "   You only do this once.\n\n"
                "Broski lives in the menu bar.\n")
        html = md(text)
        self.assertEqual(html.count("<ol>"), 1)
        self.assertEqual(html.count("<li>"), 6)
        self.assertIn('<pre><code class="language-bash">shasum -a 256 ~/Downloads/Broski-*.zip\n</code></pre>', html)
        self.assertIn("<p>You only do this once.</p>\n</li>\n</ol>", html)
        self.assertTrue(html.rstrip().endswith("<p>Broski lives in the menu bar.</p>"))

    def test_an_ordered_list_can_start_past_one(self):
        self.assertIn('<ol start="3">', md("3. three\n4. four\n"))

    def test_a_list_can_follow_a_paragraph_directly(self):
        html = md("You need:\n- a Mac\n- a key\n")
        self.assertIn("<p>You need:</p>", html)
        self.assertIn("<li>a Mac</li>", html)

    def test_a_table_with_alignment_and_a_pipe_in_code(self):
        html = md("| Role | What |\n|---|:---:|\n| Fast | `a\\|b` and **c** |\n")
        self.assertIn("<th>Role</th>", html)
        # A class, not a style attribute: the site's content security policy blocks inline styles.
        self.assertIn('<th class="align-center">What</th>', html)
        self.assertIn('<td class="align-center"><code>a|b</code> and <strong>c</strong></td>', html)
        self.assertIn('<div class="table-wrap"><table>', html)
        self.assertNotIn("style=", html)

    def test_a_table_without_outer_pipes(self):
        html = md("Role | What\n--- | ---\nFast | Filing\n\nAfter.")
        self.assertIn("<td>Fast</td><td>Filing</td>", html)
        self.assertIn("<p>After.</p>", html)

    def test_a_fence_can_carry_more_than_a_language(self):
        html = md('```json title="x.json"\n{"v": 1}\n```\n\n## After\n')
        self.assertIn('<pre><code class="language-json">{&quot;v&quot;: 1}\n</code></pre>', html)
        self.assertIn('<h2 id="after">', html)

    def test_an_unclosed_fence_is_a_problem(self):
        page = build.markdown("Text.\n\n```bash\nrun this\n\n## Lost heading\n", link=lambda url: url)
        self.assertTrue(any("never closed" in problem for problem in page.problems))

    def test_an_image_is_a_problem_until_guides_can_show_them(self):
        page = build.markdown("See ![the dashboard](shot.png).", link=lambda url: url)
        self.assertTrue(any("image" in problem for problem in page.problems))

    def test_fenced_code_is_escaped_and_keeps_blank_lines(self):
        html = md("```\nif a < b {\n\n  print(\"&\")\n}\n```\n")
        self.assertIn("<pre><code>if a &lt; b {\n\n  print(&quot;&amp;&quot;)\n}\n</code></pre>", html)

    def test_a_blockquote_and_a_rule(self):
        html = md("> Quoted **text**.\n\n---\n\nAfter.")
        self.assertIn("<blockquote>\n<p>Quoted <strong>text</strong>.</p>\n</blockquote>", html)
        self.assertIn("<hr>", html)


class LinkTests(unittest.TestCase):
    def setUp(self):
        self.site = build.Site(out=Path("/nonexistent"), site=SITE, repo=REPO)

    def test_a_link_to_another_guide_goes_to_its_page(self):
        self.assertEqual(self.site.href("models.md#roles", source="docs/talking.md", base="../../"),
                         "../../docs/models/#roles")
        self.assertEqual(self.site.href("docs/getting-started.md", source="CHANGELOG.md", base="../"),
                         "../docs/getting-started/")

    def test_a_link_to_the_changelog_goes_to_its_page(self):
        self.assertEqual(self.site.href("../CHANGELOG.md", source="docs/releasing.md", base="../../"), "../../changelog/")

    def test_a_link_to_a_repository_file_goes_to_github(self):
        self.assertEqual(self.site.href("../SECURITY.md", source="docs/privacy.md", base="../../"),
                         REPO + "/blob/main/SECURITY.md")
        self.assertEqual(self.site.href("../Sources/BroskiCore", source="docs/architecture.md", base="../../"),
                         REPO + "/tree/main/Sources/BroskiCore")

    def test_a_github_relative_link_goes_to_the_repository(self):
        self.assertEqual(self.site.href("../../../releases/latest", source="docs/getting-started.md", base="../../"),
                         REPO + "/releases/latest")
        self.assertEqual(self.site.href("../../issues", source="CHANGELOG.md", base="../"), REPO + "/issues")
        self.assertEqual(self.site.problems, [])

    def test_a_link_that_climbs_too_far_or_to_no_route_is_a_problem(self):
        # Each of these is broken on GitHub too: one level short, one too many, or not a page GitHub has.
        for url in ("../../releases/latest", "../../../../releases/latest", "../../SECURITY.md", "../../../nowhere"):
            self.site.problems = []
            self.site.href(url, source="docs/getting-started.md", base="../../")
            self.assertEqual(len(self.site.problems), 1, url)

    def test_external_and_same_page_links_are_left_alone(self):
        self.assertEqual(self.site.href("https://ollama.com", source="docs/models.md", base="../../"), "https://ollama.com")
        self.assertEqual(self.site.href("#roles", source="docs/models.md", base="../../"), "#roles")

    def test_absolute_links_for_markdown_copies(self):
        self.assertEqual(self.site.href("models.md#roles", source="docs/talking.md", base=None),
                         SITE + "/docs/models.md#roles")

    def test_a_link_to_a_missing_file_is_a_problem(self):
        self.site.href("../NOPE.md", source="docs/privacy.md", base="../../")
        self.assertTrue(any("NOPE.md" in problem for problem in self.site.problems))


class SiteTests(unittest.TestCase):
    """Builds the real site from site/ and docs/ into a temporary folder."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "site"
        cls.site = build.build(out=cls.out, site=SITE, repo=REPO, owner="someone")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def pages(self):
        return sorted(self.out.rglob("*.html"))

    def test_the_build_finds_no_problems(self):
        self.assertEqual(self.site.problems, [])

    def test_every_guide_has_a_page_and_a_markdown_copy(self):
        for doc in build.DOCS:
            slug = build.slug_of(doc.file)
            self.assertTrue((self.out / "docs" / slug / "index.html").is_file(), slug)
            self.assertTrue((self.out / "docs" / (slug + ".md")).is_file(), slug)

    def test_every_guide_has_a_short_description_of_its_own(self):
        for doc in build.DOCS:
            self.assertTrue(40 <= len(doc.description) <= 160, doc.file)
            html = (self.out / "docs" / build.slug_of(doc.file) / "index.html").read_text()
            self.assertIn('<meta name="description" content="%s">' % build.esc(doc.description), html)

    def test_every_guide_in_docs_is_on_the_site(self):
        listed = {doc.file for doc in build.DOCS}
        on_disk = {path.name for path in (build.ROOT / "docs").glob("*.md")}
        self.assertEqual(on_disk - listed, set())

    def test_every_page_has_a_title_description_canonical_and_one_h1(self):
        for page in self.pages():
            html = page.read_text()
            name = str(page.relative_to(self.out))
            self.assertRegex(html, r"<title>[^<]{10,}</title>", name)
            if name == "404.html":
                self.assertIn('name="robots" content="noindex"', html)
                continue
            description = re.search(r'<meta name="description" content="([^"]+)">', html)
            self.assertIsNotNone(description, name)
            self.assertLessEqual(len(description.group(1)), 170, name)
            self.assertRegex(html, r'<link rel="canonical" href="https://example\.test/broski/[^"]*">', name)
            self.assertEqual(len(re.findall(r"<h1[ >]", html)), 1, name)

    def test_no_placeholders_are_left(self):
        for path in self.out.rglob("*"):
            if path.suffix in {".html", ".txt", ".xml", ".md", ".webmanifest"}:
                self.assertNotRegex(path.read_text(), r"__(REPO|SITE|VERSION)__", str(path))

    def test_structured_data_is_json_and_describes_the_app(self):
        html = (self.out / "index.html").read_text()
        blocks = re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
        self.assertEqual(len(blocks), 1)
        graph = {node["@type"]: node for node in json.loads(blocks[0])["@graph"]}
        app = graph["SoftwareApplication"]
        self.assertEqual(app["softwareVersion"], build.version())
        self.assertEqual(app["offers"]["price"], "0")
        self.assertEqual(app["downloadUrl"], REPO + "/releases/latest")
        self.assertEqual(graph["SoftwareSourceCode"]["codeRepository"], REPO)

    def test_the_faq_data_matches_the_questions_on_the_page(self):
        html = (self.out / "index.html").read_text()
        data = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S).group(1))
        faq = next(node for node in data["@graph"] if node["@type"] == "FAQPage")
        on_page = re.findall(r"<summary>(.*?)</summary>", html)
        self.assertEqual([q["name"] for q in faq["mainEntity"]], on_page)
        self.assertGreaterEqual(len(on_page), 8)
        for question in faq["mainEntity"]:
            self.assertNotIn("<", question["acceptedAnswer"]["text"])

    def test_guides_have_article_and_breadcrumb_data(self):
        html = (self.out / "docs" / "models" / "index.html").read_text()
        data = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S).group(1))
        types = [node["@type"] for node in data["@graph"]]
        self.assertIn("TechArticle", types)
        self.assertIn("BreadcrumbList", types)

    def test_the_sitemap_lists_every_indexed_page(self):
        sitemap = (self.out / "sitemap.xml").read_text()
        urls = set(re.findall(r"<loc>(.*?)</loc>", sitemap))
        for page in self.pages():
            name = str(page.relative_to(self.out))
            if name == "404.html":
                continue
            url = SITE + "/" + name[: -len("index.html")]
            self.assertIn(url, urls, name)
        self.assertEqual(len(re.findall(r"<lastmod>\d{4}-\d{2}-\d{2}</lastmod>", sitemap)), len(urls))

    def test_robots_and_llms_files(self):
        robots = (self.out / "robots.txt").read_text()
        self.assertIn("Sitemap: " + SITE + "/sitemap.xml", robots)
        llms = (self.out / "llms.txt").read_text()
        self.assertTrue(llms.startswith("# Broski\n\n> "))
        for doc in build.DOCS:
            self.assertIn(SITE + "/docs/" + build.slug_of(doc.file) + ".md", llms)
        full = (self.out / "llms-full.txt").read_text()
        self.assertIn("# Choosing your AI", full)
        self.assertNotIn("](models.md", full)

    def test_the_version_is_on_the_home_page(self):
        self.assertIn("Version " + build.version(), (self.out / "index.html").read_text())

    def test_markdown_left_over_in_a_page_is_a_problem(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = build.build(out=Path(tmp) / "s", site=SITE, repo=REPO, owner="someone")
            page = Path(tmp) / "s" / "docs" / "models" / "index.html"
            page.write_text(page.read_text().replace("</h1>", "</h1>\n<p>See [this](x.md) and ```code```.</p>", 1))
            site.problems = []
            site.check()
            self.assertTrue(any("markdown" in problem for problem in site.problems), site.problems)

    def test_the_version_is_the_newest_release_tag(self):
        self.assertEqual(build.newest_tag(["v0.9.6", "v0.11.3", "v0.11.2", "v0.10.0", "nightly"]), "0.11.3")
        self.assertIsNone(build.newest_tag(["nightly"]))

    def test_site_verification_tags_are_added_when_given(self):
        with tempfile.TemporaryDirectory() as tmp:
            build.build(out=Path(tmp) / "s", site=SITE, repo=REPO, owner="someone",
                        verify={"google-site-verification": "abc123"})
            self.assertIn('<meta name="google-site-verification" content="abc123">',
                          (Path(tmp) / "s" / "index.html").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=1)
