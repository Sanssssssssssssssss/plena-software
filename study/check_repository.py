"""Check the staged publication: links, evidence hashes and accidental artifacts."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    entries = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "--stage", "-z"]).decode().split("\0")
    files = {}
    for entry in filter(None, entries):
        metadata, path = entry.split("\t", 1)
        if metadata.startswith("160000 "):
            continue
        files[path] = metadata.split()[1]
    for path in files:
        assert not any(part in path.split("/") for part in (".cache", ".venv", ".venv-wsl", "__pycache__")), path
        if "build" in path.split("/"):
            assert path.startswith("study/evidence/2026-10-04/historical-rtl/") and path.endswith("results.xml"), path
        assert not path.startswith(("study/logs/", "study/runs/", "rtl-snapshot-20260924/")), path
        assert (ROOT / path).stat().st_size < 10 * 1024**2, path
        if (ROOT / path).suffix.lower() in {".png", ".jpg", ".pdf"}:
            continue
        text = (ROOT / path).read_text(encoding="utf-8-sig", errors="replace")
        assert not re.search(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)", text), f"Credential-shaped text in {path}"
    docs = [ROOT / "README.md", ROOT / "PROVENANCE.md", *ROOT.glob("docs/*.md"),
            *ROOT.glob("study/*.md"), ROOT / "study/core/README.md"]
    for doc in docs:
        text = doc.read_text(encoding="utf-8")
        assert "E:/GPTProject2" not in text and "/mnt/e/GPTProject2" not in text, doc
        for target in re.findall(r"\]\(([^)]+)\)", text):
            if target.startswith(("https://", "http://", "#")):
                continue
            path = (doc.parent / target.split("#", 1)[0]).resolve()
            assert path.exists(), (doc, target)
            rel = path.relative_to(ROOT).as_posix()
            assert rel in files or any(f.startswith(rel + "/") for f in files), (doc, target, "not staged")
    evidence = ROOT / "study/evidence/2026-10-04"
    manifest = json.loads((evidence / "manifest.json").read_text())
    for row in manifest["files"]:
        path = evidence / row["file"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row["published_sha256"], path
        # The staged Git blob must preserve the published evidence bytes too.
        blob = subprocess.check_output(["git", "-C", str(ROOT), "cat-file", "blob", files[path.relative_to(ROOT).as_posix()]])
        assert hashlib.sha256(blob).hexdigest() == row["published_sha256"], path
        if path.suffix == ".xml":
            ET.parse(path)
    source = ROOT / "lab/rtl-prefill"
    for row in json.loads((source / "SOURCE.json").read_text())["files"]:
        path = source / row["path"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row["sha256"], path
        blob = subprocess.check_output(["git", "-C", str(ROOT), "cat-file", "blob", files[path.relative_to(ROOT).as_posix()]])
        assert hashlib.sha256(blob).hexdigest() == row["sha256"], path
    print(f"PASS: {len(files)} staged files; document links, preserved source/evidence hashes, XML and artifact boundaries")


if __name__ == "__main__":
    main()
