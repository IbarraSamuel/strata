from importlib.metadata import distribution
from pathlib import Path
import subprocess
import sys

from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging.tags import sys_tags


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        if self.target_name == "sdist":
            return

        mojo_wheel = distribution("mojo").read_text("WHEEL")
        if mojo_wheel is None:
            msg = "Mojo wheel metadata is missing"
            raise RuntimeError(msg)

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

        output = project_root / "src/strata/mojo_strata.so"
        output.parent.mkdir(parents=True, exist_ok=True)

        runtime_rpath = (
            "@loader_path/../modular/lib"
            if sys.platform == "darwin"
            else "$ORIGIN/../modular/lib"
        )
        rpaths = [runtime_rpath]

        subprocess.run(
            [
                "mojo",
                "build",
                str(source),
                "--emit",
                "shared-lib",
                "-o",
                str(output),
                *[
                    argument
                    for rpath in rpaths
                    for argument in ("-Xlinker", "-rpath", "-Xlinker", rpath)
                ],
            ],
            cwd=repository_root,
            check=True,
        )
