"""Probe for ubi9-python-312-runtime, run by images/python-312-runtime/test.

Prints one line per check: "PASS <check>: <what it saw>" or
"FAIL <check>: <error>", and for the FIPS configuration one
"ALLOWED <operation>: <result>" or "REFUSED <operation>: <error>" line each.
Exits 1 when any check failed.
"""

import bz2
import datetime
import hashlib
import importlib
import lzma
import os
import sqlite3
import sys
import urllib.request
import warnings
import zlib
import zoneinfo


failures = 0


def check(name, body):
    global failures
    try:
        print(f"PASS {name}: {body()}")
    except Exception as error:
        failures += 1
        print(f"FAIL {name}: {type(error).__name__}: {error}")


def report(name, body):
    try:
        print(f"ALLOWED {name}: {body()}")
    except Exception as error:
        print(f"REFUSED {name}: {type(error).__name__}: {error}")


# Modules that cannot exist on this platform or are not meant to be
# imported (Windows-only, GUI, the "this" and "antigravity" jokes).
NOT_EXPECTED = {
    "antigravity", "idlelib", "msilib", "msvcrt", "nt", "this", "tkinter",
    "turtle", "turtledemo", "winreg", "winsound", "ensurepip", "venv",
}


def import_standard_library():
    warnings.simplefilter("ignore")
    failed = []
    for name in sorted(sys.stdlib_module_names - NOT_EXPECTED):
        if name.startswith("_"):
            continue
        try:
            importlib.import_module(name)
        except Exception as error:
            failed.append(f"{name} ({type(error).__name__})")
    if failed:
        raise ImportError(", ".join(failed))
    return "every public module imports"


def compress_round_trip():
    data = b"x" * 4096
    for module in (zlib, bz2, lzma):
        if module.decompress(module.compress(data)) != data:
            raise ValueError(f"{module.__name__} round trip differs")
    return "zlib, bz2 and lzma round trip ok"


def chicago_noon():
    noon = datetime.datetime(2026, 7, 1, 12, tzinfo=datetime.timezone.utc)
    chicago = noon.astimezone(zoneinfo.ZoneInfo("America/Chicago"))
    return chicago.strftime("%H:%M")


def github():
    with urllib.request.urlopen("https://github.com/", timeout=20) as reply:
        return f"HTTP {reply.status}"


check("runs as", lambda: f"uid {os.getuid()}")
check("standard library", import_standard_library)
check("sqlite", lambda: sqlite3.connect(":memory:").execute(
    "select sqlite_version()").fetchone()[0])
check("compression", compress_round_trip)
check("time zones", chicago_noon)
check("HTTPS to github.com", github)

report("MD5", lambda: hashlib.md5(b"x").hexdigest())
report("MD5 with usedforsecurity=False",
       lambda: hashlib.md5(b"x", usedforsecurity=False).hexdigest())
report("SHA-256", lambda: hashlib.sha256(b"x").hexdigest())

sys.exit(1 if failures else 0)
