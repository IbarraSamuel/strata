import shutil
import subprocess  # ruff: ignore[suspicious-subprocess-import]
import sys
from importlib.metadata import PackageNotFoundError, distribution
from pathlib import Path
from typing import override

from hatchling.builders.config import BuilderConfig
from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging.tags import sys_tags


def _read_modular_wheel_metadata() -> str:
    """Read the `WHEEL` metadata text from `mojo-compiler`, `mojo`, or `max-core`.

    Returns
    -------
    str
        Contents of the package `WHEEL` metadata file.

    Raises
    ------
    RuntimeError
        If none of the Modular distributions provide `WHEEL` metadata.
    """
    for dist_name in ("mojo-compiler", "mojo", "max-core"):
        try:
            wheel_text = distribution(dist_name).read_text("WHEEL")
        except PackageNotFoundError:
            continue
        if wheel_text is not None:
            return wheel_text
    msg = (
        "Modular wheel metadata is missing "
        "(expected mojo-compiler, mojo, or max-core)"
    )
    raise RuntimeError(msg)


def _has_max_gpu_support() -> bool:
    """Check whether `max` / `max-core` / `max-mojo-libs` is available.

    Returns
    -------
    bool
        `True` if the MAX Mojo GPU libraries are installed in the build environment.
    """
    for dist_name in ("max-mojo-libs", "max-core", "max"):
        try:
            distribution(dist_name)
        except PackageNotFoundError:
            continue
        else:
            return True

    mojo_bin = shutil.which("mojo")
    if mojo_bin is not None:
        conda_max = Path(mojo_bin).resolve().parent.parent / "lib/mojo/max.mojoc"
        if conda_max.is_file():
            return True
    return False


class CustomBuildHook(BuildHookInterface[BuilderConfig]):
    @override
    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        if self.target_name == "sdist":
            return

        mojo_wheel = _read_modular_wheel_metadata()

        platform_tags = {
            line.partition(":")[2].strip().split("-", maxsplit=2)[2]
            for line in mojo_wheel.splitlines()
            if line.startswith("Tag:")
        }
        if len(platform_tags) != 1 or "any" in platform_tags:
            msg = f"Expected one platform-specific Mojo wheel tag, got {platform_tags}"
            raise RuntimeError(msg)

        python_tag = next(
            (
                tag
                for tag in sys_tags()
                if tag.interpreter.startswith("cp") and tag.abi.startswith("cp")
            ),
            None,
        )
        if python_tag is None:
            msg = "Could not determine the active CPython wheel tag"
            raise RuntimeError(msg)

        build_data["tag"] = (
            f"{python_tag.interpreter}-{python_tag.abi}-{next(iter(platform_tags))}"
        )
        build_data["pure_python"] = False

        project_root = Path(self.root)
        repository_root = project_root.parent
        source = project_root / "src/interop/python_interop.mojo"
        if not source.is_file():
            source = repository_root / "src/interop/python_interop.mojo"
        if not source.is_file():
            msg = f"Mojo source file not found: {source}"
            raise FileNotFoundError(msg)

        source_root = source.parent.parent.parent
        gpu_source = project_root / "src/interop/python_gpu_interop.mojo"
        use_gpu_entry = _has_max_gpu_support() and gpu_source.is_file()

        output = project_root / "src/strata/mojo_strata.so"
        output.parent.mkdir(parents=True, exist_ok=True)

        runtime_rpath = (
            "@loader_path/../modular/lib"
            if sys.platform == "darwin"
            else "$ORIGIN/../modular/lib"
        )
        rpaths = [runtime_rpath]

        cmd = ["mojo", "build"]
        if use_gpu_entry:
            cmd.extend(["-I", str(source_root), str(gpu_source)])
        else:
            cmd.append(str(source))
        cmd.extend(
            [
                "--emit",
                "shared-lib",
                "-o",
                str(output),
                *[
                    argument
                    for rpath in rpaths
                    for argument in ("-Xlinker", "-rpath", "-Xlinker", rpath)
                ],
            ]
        )

        subprocess.run(  # ruff: ignore[subprocess-without-shell-equals-true]
            cmd,
            cwd=source_root,
            check=True,
        )
