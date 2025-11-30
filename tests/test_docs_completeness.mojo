from pathlib import _dir_of_current_file, Path
import subprocess

alias CMD = "magic run mojo doc --diagnose-missing-doc-strings --validate-doc-strings {}"


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


fn _run_doctest_cmd(file: Path) raises:
    path = String(file)
    cmd = StaticString(CMD).format(path)
    res = subprocess.run(cmd)
    if not ('"decl":' in res and '"version":' in res):
        raise Error(res)


fn test_docs_completeness() raises:
    var files = _list_files["strata.generic"]()

    for file in files:
        _run_doctest_cmd(file)


fn main() raises:
    from testing import TestSuite

    TestSuite.discover_tests[(test_docs_completeness,)]().run()
