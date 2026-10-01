"""Generate identical offline app notices and public static pages. No user data."""
from pathlib import Path
import json, html, shutil
ROOT=Path(__file__).resolve().parents[1]
data=json.loads((ROOT/'AppStore/legal-content.json').read_text())
OUT=ROOT/'AppStore/site';OUT.mkdir(parents=True,exist_ok=True)
esc=html.escape
style='''*{box-sizing:border-box}body{margin:0;background:#edf3f8;color:#192e47;font:18px/1.65 system-ui,-apple-system,sans-serif}main{max-width:760px;margin:5vh auto;padding:32px clamp(20px,5vw,48px);background:#fff;border-radius:28px;box-shadow:0 18px 60px #192e4710}nav{display:flex;gap:20px;flex-wrap:wrap}a{color:#24568a;text-underline-offset:4px}a:focus-visible{outline:3px solid #24568a;outline-offset:4px}h1{font-size:clamp(30px,6vw,44px);line-height:1.15}h2{font-size:21px;margin-top:28px}p{overflow-wrap:anywhere}.meta,footer{font-size:15px;color:#586b7e}footer{margin-top:32px}'''
nav='<nav aria-label="CloudChess support">'+''.join(f'<a href="{p["id"]}.html">{esc(p["title"])}</a>' for p in data['pages'])+'</nav>'
def page(title,body):
 return f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="description" content="CloudChess privacy, support and open-source information"><title>{esc(title)} · CloudChess</title><style>{style}</style></head><body><main>{nav}<h1>{esc(title)}</h1>{body}<footer>CloudChess · Updated {esc(data["updated"])}</footer></main></body></html>'
for p in data['pages']:
 body=''.join(f'<section><h2>{esc(s["title"])}</h2><p>{esc(s["body"])}</p></section>' for s in p['sections'])
 if p['id']=='support':body=f'<p><a href="mailto:{data["contact"]}?subject=CloudChess%20support">Email support</a></p>'+body
 body+=''.join(f'<p><a href="{esc(link["url"],quote=True)}">{esc(link["title"])}</a></p>' for link in p['links'])
 if p['id']=='licenses':body+='<p><a href="stockfish-license.txt">GNU General Public License v3</a> · <a href="opening-book-CC0.txt">CC0 license</a></p>'
 (OUT/f'{p["id"]}.html').write_text(page(p['title'],body))
(OUT/'index.html').write_text(page('CloudChess','<p>Privacy, support and open-source information for the CloudChess iPhone and iPad app.</p>'))
(OUT/'.nojekyll').write_text('')
for source,dest in [('Copying.txt','stockfish-license.txt'),('opening-book-CC0.txt','opening-book-CC0.txt')]:shutil.copyfile(ROOT/'CloudChess/EngineResources'/source,OUT/dest)
shutil.copyfile(ROOT/'AppStore/legal-content.json',ROOT/'CloudChess/EngineResources/legal-content.json')
print('Built public pages and matching offline app content.')
