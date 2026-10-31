"""Test documentation completeness for all Mojo source files."""

from std.pathlib import _dir_of_current_file, Path
import std.subprocess as subprocess

comptime CMD = "mojo doc --diagnose-missing-doc-strings -Werror -I {} {} 2>&1"


def _flatten_files(var path: Path, mut files: List[Path]) raises:
    if path.is_file():
        if String(path).endswith(".mojo"):
            files.append(path)
        return

    for p in path.listdir():
        _flatten_files(path / p, files)


def _list_files(var package_dir: Path) raises -> List[Path]:
    var files = List[Path]()
    _flatten_files(package_dir^, files)
    return files^


def _run_doctest_cmd(package_dir: Path, file: Path) raises -> String:
    var cmd = StaticString(CMD).format(String(package_dir), String(file))
    return subprocess.run(cmd)


def test_docs_completeness() raises:
    var package_dir = _dir_of_current_file() / ".." / "src"
    var files = _list_files(package_dir)
    var errors = List[String]()

    for file in files:
        var res = _run_doctest_cmd(package_dir, file)
        if not ('"decl"' in res and '"version"' in res):
            errors.append(String(file) + ":\n" + res)

    if len(errors) > 0:
        raise Error("\n\n".join(errors))


def main() raises:
    from std.testing import TestSuite

    TestSuite.discover_tests[(test_docs_completeness,)]().run()
