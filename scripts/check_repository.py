"""Check complete imports, comment-only changes, evidence hashes and authored links."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    entries = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '--stage', '-z']).decode().split('\0')
    files = {}
    for entry in filter(None, entries):
        meta, path = entry.split('\t', 1)
        assert not meta.startswith('160000 '), f'Unmaterialized submodule: {path}'
        files[path] = meta.split()[1]
    manifest = json.loads((ROOT / 'docs/provenance/source-manifest.json').read_text(encoding='utf-8'))
    for row in manifest['files']:
        path = ROOT / row['path']
        assert row['path'] in files, f'Missing import in Git: {row["path"]}'
        data = path.read_bytes()
        assert not data.startswith(b'version https://git-lfs.github.com/spec/v1'), f'LFS placeholder: {path}'
        assert digest(data) == row['sha256'], f'Changed import: {path}'
        if row.get('change', '').startswith('Chinese comments only'):
            clean = b''.join(line for line in data.splitlines(keepends=True) if '学习注：'.encode() not in line)
            assert digest(clean) == row['source_sha256'], f'Non-comment change: {path}'
    for path in files:
        assert not any(p in path.split('/') for p in ('.venv', '.venv-wsl', '.cache', '__pycache__')), path
        data = (ROOT / path).read_bytes()
        assert len(data) < 95 * 1024**2, f'Oversized Git file: {path}'
        assert not re.search(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)', data), f'Credential-shaped content: {path}'
    docs = [ROOT / 'README.md', ROOT / 'PROVENANCE.md', *ROOT.glob('docs/*.md')]
    for doc in docs:
        for target in re.findall(r'\]\(([^)]+)\)', doc.read_text(encoding='utf-8')):
            if target.startswith(('https://', 'http://', '#')):
                continue
            path = (doc.parent / target.split('#', 1)[0]).resolve()
            assert path.exists(), f'Broken link: {doc.name} -> {target}'
            rel = path.relative_to(ROOT).as_posix()
            assert rel in files or any(f.startswith(rel + '/') for f in files), f'Untracked link target: {target}'
    for evidence_manifest in ROOT.glob('evidence/*/manifest.json'):
        for row in json.loads(evidence_manifest.read_text(encoding='utf-8'))['files']:
            assert digest((evidence_manifest.parent / row['file']).read_bytes()) == row['published_sha256'], row['file']
    print(f'PASS: {len(files)} Git files; {len(manifest["files"])} imported files; zero gitlinks; comment-only source edits; historical hashes; authored document links')


if __name__ == '__main__':
    main()
