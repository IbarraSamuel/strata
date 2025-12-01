from pathlib import _dir_of_current_file, Path
from algorithm import sync_parallelize
import subprocess

alias CMD = "mojo doc --diagnose-missing-doc-strings --validate-doc-strings {}"


fn _flatten_files(var path: Path, mut files: List[Path]) raises:
    if path.is_file():
        files.append(path)
        return

    for p in path.listdir():
        _flatten_files(path / p, files)


fn _list_files[package: StringLiteral]() raises -> List[Path]:
    var package_dir = Path(package)
    files = List[Path]()
    _flatten_files(package_dir^, files)
    return files^


fn _run_doctest_cmd(file: Path) raises -> String:
    path = String(file)
    cmd = StaticString(CMD).format(path)
    return subprocess.run(cmd)


fn test_docs_completeness() raises:
    var files = _list_files["../src"]()
    var results = List[String](length=len(files), fill="")

    @parameter
    fn calc_file_docs(i: Int) raises:
        ref file = files[i]
        results[i] = _run_doctest_cmd(file)

    sync_parallelize[calc_file_docs](len(files))

    var errors = [
        res for res in results if not ('"decl"' in res and '"version"' in res)
    ]

    if errors:
        raise "\n\n".join(errors)


fn main() raises:
    from testing import TestSuite

    TestSuite.discover_tests[(test_docs_completeness,)]().run()
