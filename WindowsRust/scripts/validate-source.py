"""Portable SOURCE validation only. Does not compile or execute Windows code."""
from pathlib import Path
from html.parser import HTMLParser
import json, tomllib, re, subprocess, shutil
ROOT=Path(__file__).resolve().parents[1]
class IDs(HTMLParser):
    def __init__(self): super().__init__(); self.ids=set()
    def handle_starttag(self,tag,attrs):
        for k,v in attrs:
            if k=='id':
                assert v not in self.ids, f'duplicate HTML ID: {v}'
                self.ids.add(v)

def main():
    for p in ROOT.rglob('*.json'):
        if not any(s in p.parts for s in ('target','dist','ffmpeg','gen')): json.loads(p.read_text(encoding='utf-8-sig'))
    for p in ROOT.rglob('*.toml'):
        if not any(s in p.parts for s in ('target','dist','ffmpeg')): tomllib.loads(p.read_text(encoding='utf-8'))
    for p in (ROOT/'frontend').glob('*.mjs'):
        subprocess.run(['node','--check',str(p)],check=True)
    html=IDs();html.feed((ROOT/'frontend'/'index.html').read_text(encoding='utf-8'))
    js=(ROOT/'frontend'/'app.mjs').read_text(encoding='utf-8')
    for identifier in re.findall(r"\$\('([^']+)'\)",js): assert identifier in html.ids, identifier
    assert 'getDisplayMedia(' not in js
    assert '.innerHTML' not in js
    assert 'eval(' not in js
    conf=json.loads((ROOT/'src-tauri'/'tauri.conf.json').read_text())
    assert (ROOT/'src-tauri'/conf['build']['frontendDist']).is_dir()
    for icon in conf['bundle']['icon']: assert (ROOT/'src-tauri'/icon).is_file()
    for cap in conf['app']['security']['capabilities']: assert (ROOT/'src-tauri'/'capabilities'/(cap+'.json')).is_file()
    subprocess.run(['node','--test','tests/frontend.test.mjs'],cwd=ROOT,check=True)
    print('Portable source checks passed. Rust compilation and Windows native recording NOT RUN.')
if __name__=='__main__': main()
