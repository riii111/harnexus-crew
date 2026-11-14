"""Where the built executables are: the environment names them, and a release build in this checkout is the default."""

import os

from .cases import REPO

BUILD = REPO / "_build" / "native" / "release" / "build"

_DEFAULTS = {
    "HARNEXUS_CREW_NATIVE": BUILD / "cmd" / "main" / "main.exe",
    "HARNEXUS_STORE_PROBE": BUILD / "test" / "probes" / "store" / "store.exe",
    "HARNEXUS_MARKDOWN_PROBE": BUILD / "test" / "probes" / "markdown" / "markdown.exe",
    "HARNEXUS_PROMPT_PROBE": BUILD / "test" / "probes" / "prompt" / "prompt.exe",
}


def require_binary(variable):
    """The executable, or a failure that names how to build it: a missing build never skips a test."""
    path = os.environ.get(variable) or str(_DEFAULTS[variable])
    if not os.access(path, os.X_OK):
        raise FileNotFoundError(f"{path} is missing; run `moon build --target native --release` or set {variable}")
    return path
