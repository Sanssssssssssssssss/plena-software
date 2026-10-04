"""Fetch pinned public sources. --check only reports the current checkout.

The Prefill branch's missing Tools pin is replaced explicitly; do not use a
blind recursive update on PLENA-Prefill, which would request that missing SHA.
"""
from pathlib import Path
import argparse
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TOOLS_SHA = "0f10353947eb442c73f27f4ed30925f3e83e73a1"


def git(directory, *args, capture=False):
    return subprocess.run(["git", "-C", str(directory), *args], check=True,
                          text=True, stdout=subprocess.PIPE if capture else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check:
        git(ROOT, "submodule", "update", "--init", "PLENA", "PLENA_Doc", "PLENA-Prefill")
        # CPU/RTL study paths do not need the Software/OSWorld GUI benchmark.
        git(ROOT / "PLENA", "submodule", "update", "--init", "--recursive",
            "PLENA_RTL", "PLENA_Simulator")
        research = ROOT / "PLENA-Prefill"
        git(research, "submodule", "update", "--init", "PLENA_Compiler")
        tools = research / "PLENA_Tools"
        if not (tools / ".git").exists():
            git(research, "clone", "https://github.com/AICrossSim/PLENA_Tools.git", str(tools))
        if git(tools, "status", "--porcelain", capture=True).stdout.strip():
            raise RuntimeError("PLENA-Prefill/PLENA_Tools has local changes; preserve them before checkout")
        git(tools, "checkout", "--detach", TOOLS_SHA)
    pins = {
        "PLENA": "5b06df9ab13840b8834766311313e2d27bfbebed",
        "PLENA_Doc": "7bf6d7636a3298159686773f4343cb7d7d743f17",
        "PLENA-Prefill": "fddfcb9a7c3eaa1ad9f1c24da829a4422b324650",
        "PLENA/PLENA_RTL": "783ee48ea81607308aba40a7dfe83b52868d1b71",
        "PLENA/PLENA_Simulator": "a4b3e7deb8dd78c1950922ea89085b819cf5a9de",
        "PLENA-Prefill/PLENA_Compiler": "0ba3b657725bf083feec06c8e356e2d6235cd4d5",
        "PLENA-Prefill/PLENA_Tools": TOOLS_SHA,
    }
    results = {}
    for path, expected in pins.items():
        actual = (git(ROOT / path, "rev-parse", "HEAD", capture=True).stdout.strip()
                  if (ROOT / path / ".git").exists() else None)
        results[path] = {"expected": expected, "actual": actual, "match": actual == expected}
    print(json.dumps(results, indent=2))
    if not all(row["match"] for row in results.values()):
        raise SystemExit("Missing or mismatched sources; run study/bootstrap.py before experiments")
    print("Source pins verified. Prefill Tools uses the documented substitute, not its unavailable original pin.")


if __name__ == "__main__":
    main()
