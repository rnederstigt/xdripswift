"""Shared source extraction, Swift fixture rendering and isolated compiler execution."""
from contextlib import contextmanager
from pathlib import Path
import re
import subprocess
import tempfile

ADDON = Path(__file__).resolve().parents[1]
REPO = ADDON.parent
BASELINE = '53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8'


def block(source, marker):
    """Read the body after a marker ending in '{'; fail if it is unbalanced.

    This is a small extractor for the selected repository methods, not a Swift
    parser. Braces in their comments/string literals must also balance.
    """
    start = source.index(marker) + len(marker)
    depth, end = 1, start
    while depth:
        if end == len(source):
            raise ValueError(f'Unbalanced Swift block: {marker}')
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end - 1]


def declaration(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    header = source[start:brace + 1]
    return header + block(source[start:], header) + '}'


def fixture(name, **sources):
    """Insert current production code into explicitly marked Swift fixtures.

    Require an exact key match so a renamed/missing marker cannot silently leave
    a production method out of a test. Replacement source is never re-rendered.
    """
    template = (ADDON / 'Tests/Fixtures' / (name + '.swift')).read_text()
    pattern = r'/\* @source:(\w+) \*/'
    markers = set(re.findall(pattern, template))
    if markers != sources.keys():
        raise ValueError(f'{name}: fixture markers {markers} != supplied sources {set(sources)}')
    return re.sub(pattern, lambda match: sources[match[1]], template)


@contextmanager
def test_directory(prefix):
    """Remove generated sources, executables and compiler caches on success or failure."""
    with tempfile.TemporaryDirectory(prefix=prefix) as directory:
        yield Path(directory)


def run_swift(executable, sources, *, flags=(), timeout=30):
    """Keep independent doubles in separate executables; never run a failed build."""
    subprocess.run([
        'xcrun', 'swiftc', *flags,
        '-module-cache-path', str(executable.parent / 'module-cache'),
        *map(str, sources), '-o', str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=timeout)
