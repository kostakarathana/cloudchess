"""Legal full-game histories and strong, stable three-way position labels.
CC0 Lichess source already used by the bundled opening book. Reproducible cache.
"""
import chess,chess.pgn,json,hashlib,subprocess,random,concurrent.futures,time
from pathlib import Path
R=Path(__file__).resolve().parents[1];OUT=R/'training/judgment-v1';OUT.mkdir(exist_ok=True)
NET=R/'CloudChess/EngineResources/nn-1a298aa575a0.nnue';BIN='/tmp/cc-v5-engine'
class Engine:
 def __init__(self):self.p=subprocess.Popen([BIN,str(NET)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
 def call(self,**r):
  self.p.stdin.write(json.dumps(r)+'\n');self.p.stdin.flush();v=json.loads(self.p.stdout.readline());assert 'error' not in v,v;return v
 def close(self):self.p.stdin.close();self.p.wait()
def label(cp):return 'white' if cp>50 else ('black' if cp< -50 else 'even')
def rating(cp,material,pieces,legal):
 deceptive=(cp*material<0)
 if abs(cp)>50:r=2850-650*__import__('math').log2(1+(abs(cp)-50)/70)+180*deceptive+min(150,legal*3)
 else:r=650+pieces*24+min(800,abs(material)*140)+abs(cp)*7
 return round(max(400,min(3000,r)))
scouts=OUT/'scouts.jsonl'
if not scouts.exists():
 e=Engine();rng=random.Random(62919);count=0
 with scouts.open('w') as target,(R.parent/'chess-lab/data/opening-sources/lichess-2013-01.pgn').open() as source:
  for gameIndex in range(2500):
   g=chess.pgn.read_game(source)
   if g is None:break
   b=g.board();moves=[]
   for i,m in enumerate(g.mainline_moves()):
    moves.append(m.uci());b.push(m)
    if i<15 or i%9!=gameIndex%9 or b.is_game_over(claim_draw=True):continue
    state=e.call(action='analyse',initial=chess.STARTING_FEN,moves=moves,nodes=18000,multipv=1)
    rows=state.get('evaluations',[])
    if not rows or rows[0]['cp'] is None:continue
    cp=rows[0]['cp']*(1 if b.turn else -1)
    if abs(cp)>1500:continue
    values={1:1,2:3,3:3,4:5,5:9,6:0}
    material=sum(values[p.piece_type]*(1 if p.color else -1) for p in b.piece_map().values())
    row=dict(id=hashlib.sha256((' '.join(moves)).encode()).hexdigest()[:20],history=moves.copy(),fen=b.fen(),scoutCP=cp,material=material,pieces=len(b.piece_map()),source='Lichess CC0 2013-01',game=g.headers.get('Site',''))
    target.write(json.dumps(row)+'\n');target.flush();count+=1
    if count%100==0:print('scouts',count,flush=True)
    if count>=2400:break
   if count>=2400:break
 e.close()
rows=[json.loads(x) for x in scouts.read_text().splitlines()];rng=random.Random(5911);rng.shuffle(rows)
# Stable bands across each answer, deliberately including material deceptions.
groups={}
for x in rows:
 cls=label(x['scoutCP']);band=min(5,int(rating(x['scoutCP'],x['material'],x['pieces'],25)//500))
 groups.setdefault((cls,band),[]).append(x)
selected=[]
for key,group in sorted(groups.items()):
 group.sort(key=lambda x:(not(x['material']*x['scoutCP']<0),x['id']))
 selected.extend(group[:10])
verified=OUT/'verified.jsonl';done={x['id'] for x in map(json.loads,verified.read_text().splitlines())} if verified.exists() else set()
def certify(x):
 e=Engine()
 try:
  r=e.call(action='analyse',initial=chess.STARTING_FEN,moves=x['history'],nodes=2000000,multipv=1)
  if r.get('result') or not r.get('evaluations') or r['evaluations'][0]['cp'] is None:return None
  cp=r['evaluations'][0]['cp']*(1 if r['turn']=='white' else -1);deep=cp;budget=2000000
  if abs(cp)<180:
   d=e.call(action='analyse',initial=chess.STARTING_FEN,moves=x['history'],nodes=8000000,multipv=1)
   if not d.get('evaluations') or d['evaluations'][0]['cp'] is None:return None
   deep=d['evaluations'][0]['cp']*(1 if d['turn']=='white' else -1);budget=8000000
  if label(cp)!=label(deep) or abs(abs(deep)-50)<12:return None
  return dict(id=x['id'],initial=chess.STARTING_FEN,history=x['history'],fen=r['fen'],whiteCP=deep,screenCP=cp,verdict=label(deep),rating=rating(deep,x['material'],x['pieces'],len(r['legal'])),material=x['material'],capturedWhite=r['capturedWhite'],capturedBlack=r['capturedBlack'],line=r['evaluations'][0]['pv'],nodes=budget,source=x['source'],game=x['game'])
 finally:e.close()
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool,verified.open('a') as f:
 for value in pool.map(certify,[x for x in selected if x['id'] not in done]):
  if value:f.write(json.dumps(value)+'\n');f.flush();print('verified',value['verdict'],value['rating'],value['whiteCP'],flush=True)
result=[json.loads(x) for x in verified.read_text().splitlines()]
assert all(sum(x['verdict']==c for x in result)>=10 for c in ['white','black','even'])
(R/'CloudChess/EngineResources/judgment-positions.json').write_text(json.dumps(result,separators=(',',':')))
(R/'reports/judgment-corpus-v1.json').write_text(json.dumps(dict(positions=len(result),classes={c:sum(x['verdict']==c for x in result) for c in ['white','black','even']},materialDeceptions=sum(x['material']*x['whiteCP']<0 for x in result),source='Lichess CC0 January 2013',minimumSearchNodes=2000000,boundaryRecheckNodes=8000000,engineSHA256=hashlib.sha256(Path(BIN).read_bytes()).hexdigest()),indent=2))
