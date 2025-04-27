from pathlib import _dir_of_current_file, Path
import subprocess

alias CMD = "magic run mojo doc --diagnose-missing-doc-strings --validate-doc-strings {}"


fn test_docs_completeness() raises:
    var package = Path("move")
    files = List[Path]()
    _flatten_files(package, files)

    for file in files:
        path = String(file[])
        cmd = StaticString(CMD).format(path)
        res = subprocess.run(cmd)
        if not ('"decl":' in res and '"version":' in res):
            raise Error(res)


fn _flatten_files(owned path: Path, mut files: List[Path]) raises:
    if path.is_file():
        files.append(path)
        return

    for p in path.listdir():
        _flatten_files(path / p[], files)
