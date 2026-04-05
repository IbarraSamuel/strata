from std.pathlib import _dir_of_current_file, Path
from std.algorithm import sync_parallelize
import std.subprocess as subprocess

comptime CMD = "mojo doc --diagnose-missing-doc-strings -Werror {}"


def _flatten_files(var path: Path, mut files: List[Path]) raises:
    if path.is_file():
        files.append(path)
        return

    for p in path.listdir():
        _flatten_files(path / p, files)


def _list_files(var package_dir: Path) raises -> List[Path]:
    files = List[Path]()
    _flatten_files(package_dir^, files)
    return files^


def _run_doctest_cmd(file: Path) raises -> String:
    path = String(file)
    cmd = StaticString(CMD).format(path)
    return subprocess.run(cmd)


def test_docs_completeness() raises:
    var package_dir = _dir_of_current_file() / ".." / "src"
    var files = _list_files(package_dir)
    var results = List[String](length=len(files), fill="")

    @parameter
    def calc_file_docs(i: Int) raises:
        ref file = files[i]
        results[i] = _run_doctest_cmd(file)

    sync_parallelize[calc_file_docs](len(files))

    var errors = [
        res for res in results if not ('"decl"' in res and '"version"' in res)
    ]

    if errors:
        raise "\n\n".join(errors)


def main() raises:
    from std.testing import TestSuite

    TestSuite.discover_tests[(test_docs_completeness,)]().run()
