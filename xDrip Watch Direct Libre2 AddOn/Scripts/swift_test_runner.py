"""Shared host-test setup; each check selects its own sources and compiler flags."""
from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile


@contextmanager
def test_directory(prefix):
    """Keep generated sources, binaries and compiler caches in one temporary directory."""
    with tempfile.TemporaryDirectory(prefix=prefix) as directory:
        yield Path(directory)


def run_swift(executable, sources, *, flags=(), timeout=None):
    """Compile, then run only on success. Propagate failures and retain caller timeouts."""
    subprocess.run([
        'xcrun', 'swiftc', *flags,
        '-module-cache-path', str(executable.parent / 'module-cache'),
        *map(str, sources), '-o', str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=timeout)
