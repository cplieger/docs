"""Tests for scripts/snippets.py, run against scratch trees. python3 -m unittest discover -s scripts"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "snippets.py"
EXAMPLE = "services:\n  app:\n    image: busybox:1.37.0\n"
GOOD_BLOCK = "<!-- include: examples/a/compose.yaml -->\n\n```yaml\n" + EXAMPLE + "```\n\n<!-- /include -->\n"


class SnippetsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "examples/a").mkdir(parents=True)
        (self.root / "examples/a/compose.yaml").write_text(EXAMPLE)
        (self.root / "docs").mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def page(self, text: str) -> Path:
        path = self.root / "docs/page.md"
        path.write_text("# Page\n\n" + text)
        return path

    def run_script(self, mode: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), mode, "--root", str(self.root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_check_fails(self, expected: str) -> None:
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(expected, result.stderr)

    def test_check_passes_when_every_block_matches_its_file(self) -> None:
        self.page(GOOD_BLOCK)
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_names_a_block_that_differs_from_its_file(self) -> None:
        self.page(GOOD_BLOCK.replace("busybox:1.37.0", "busybox:1.36.0"))
        self.assert_check_fails("docs/page.md:3: block differs from examples/a/compose.yaml")

    def test_write_repairs_a_block_that_differs(self) -> None:
        self.page(GOOD_BLOCK.replace("busybox:1.37.0", "busybox:1.36.0"))
        self.assertEqual(self.run_script("--write").returncode, 0)
        self.assertEqual(self.run_script("--check").returncode, 0)

    def test_check_refuses_a_code_block_outside_a_marker(self) -> None:
        self.page(GOOD_BLOCK + "\nRun this:\n\n```sh\ndocker compose up -d\n```\n")
        self.assert_check_fails("docs/page.md:15: code block outside an include marker")

    def test_check_refuses_a_tilde_fence_outside_a_marker(self) -> None:
        self.page(GOOD_BLOCK + "\n~~~\nplain\n~~~\n")
        self.assert_check_fails("docs/page.md:13: code block outside an include marker")

    def test_check_refuses_a_close_marker_with_no_open_marker(self) -> None:
        self.page(GOOD_BLOCK + "\n<!-- /include -->\n")
        self.assert_check_fails("docs/page.md:13: <!-- /include --> with no include marker before it")

    def test_check_refuses_a_malformed_marker(self) -> None:
        self.page(GOOD_BLOCK + "\n<!-- include examples/a/compose.yaml -->\n")
        self.assert_check_fails("docs/page.md:13: malformed include marker")

    def test_check_refuses_a_marker_nested_in_another_block(self) -> None:
        nested = GOOD_BLOCK.replace("\n\n```yaml", "\n<!-- include: examples/a/compose.yaml -->\n\n```yaml", 1)
        self.page(nested)
        self.assert_check_fails("docs/page.md:4: include marker inside another include block")

    def test_check_names_an_example_file_no_page_shows(self) -> None:
        self.page(GOOD_BLOCK)
        (self.root / "examples/a/extra.yaml").write_text("x: 1\n")
        self.assert_check_fails("examples/a/extra.yaml: no page includes it")

    def assert_refused_in_both_modes(self, path: str, body: str) -> None:
        text = f"<!-- include: {path} -->\n\n```text\n{body}```\n\n<!-- /include -->\n"
        page = self.page(GOOD_BLOCK + "\n" + text)
        before = page.read_text()
        for mode in ("--check", "--write"):
            with self.subTest(mode=mode):
                result = self.run_script(mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"include path is not a file under examples/: {path}", result.stderr)
                self.assertEqual(page.read_text(), before)

    def test_both_modes_refuse_a_file_at_the_repository_root(self) -> None:
        (self.root / "README.md").write_text("# readme\n")
        self.assert_refused_in_both_modes("README.md", "# readme\n")

    def test_both_modes_refuse_a_path_that_climbs_out_of_examples(self) -> None:
        (self.root / "outside.txt").write_text("outside\n")
        self.assert_refused_in_both_modes("examples/../outside.txt", "outside\n")

    def test_both_modes_refuse_a_path_outside_the_repository(self) -> None:
        outside = Path(self.tmp.name).parent / f"{self.root.name}-outside.txt"
        outside.write_text("outside\n")
        self.addCleanup(outside.unlink)
        self.assert_refused_in_both_modes(f"examples/../../{outside.name}", "outside\n")

    def test_both_modes_refuse_an_absolute_path(self) -> None:
        absolute = self.root / "examples/a/compose.yaml"
        self.assert_refused_in_both_modes(absolute.as_posix(), EXAMPLE)


if __name__ == "__main__":
    unittest.main()
