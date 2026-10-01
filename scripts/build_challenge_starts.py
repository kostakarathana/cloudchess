"""Generate legal open-play seeds; full-strength Stockfish gates every export."""
import json,random,subprocess,hashlib,csv
from pathlib import Path
import chess
ROOT=Path(__file__).resolve().parents[1]
p=subprocess.Popen(['/tmp/cloudchess-native-engine',str(ROOT/'CloudChess/EngineResources/nn-1a298aa575a0.nnue')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
def call(r):
 p.stdin.write(json.dumps(r)+'\n');p.stdin.flush();v=json.loads(p.stdout.readline());assert 'error' not in v,v;return v
rng=random.Random(9371);out=[];seen=set()
cache=ROOT/"training/open-play-starts.json"
if cache.exists():out=json.loads(cache.read_text());seen={x["fen"] for x in out}
def accept(b,kind):
 if b.fen() in seen:return False
 r=call(dict(action='analyse',initial=b.fen(),nodes=2000000,multipv=1))
 if r.get('result') or not r.get('evaluations'):return False
 e=r['evaluations'][0];cp=e['cp']
 if cp is None or not(abs(cp)<=10 if kind=='tenMoves' else 180<=cp<=650):return False
 seen.add(b.fen());uid=hashlib.sha256((kind+b.fen()).encode()).hexdigest()[:24]
 out.append(dict(id=uid,fen=b.fen(),columns=8,rows=8,mate=0,gain=0,plies=20 if kind=='tenMoves' else 400,rating=1400,uncertainty=650,complexity=60,seconds=180 if kind=='tenMoves' else 300,tags=['plan:improvement' if kind=='tenMoves' else 'conversion'],line=e['pv'],source='generated:'+uid,nodes=e['nodes'],challengeType=kind,initialEvaluation=cp,difficultyVersion='open-play-v1'))
 cache.write_text(json.dumps(out));print(kind,len([x for x in out if x['challengeType']==kind]),cp,flush=True);return True
# Diverse legal random walks using searched candidate moves, never edited boards.
for game in range(400):
 if sum(x['challengeType']=='tenMoves' for x in out)>=32:break
 b=chess.Board()
 for ply in range(rng.randrange(12,42)):
  if b.is_game_over():break
  r=call(dict(action='analyse',initial=b.fen(),nodes=20000,multipv=3));rows=r.get('evaluations',[])
  rows=[x for x in rows if x['cp'] is not None]
  if not rows:break
  best=max(x['cp'] for x in rows);choices=[x for x in rows if best-x['cp']<=60]
  b.push_uci(rng.choice(choices)['pv'][0])
 if not b.is_game_over():accept(b,'tenMoves')
# Winning source positions are legally reached through their recorded setup move.
with (ROOT.parent/'chess-lab/data/lichess-expansion.csv').open() as f:
 for row in csv.DictReader(f):
  if sum(x['challengeType']=='finish' for x in out)>=32:break
  if int(row['Rating'])>1900 or int(row['Rating'])<1000:continue
  b=chess.Board(row['FEN']);b.push_uci(row['Moves'].split()[0])
  quick=call(dict(action='analyse',initial=b.fen(),nodes=20000,multipv=1)).get('evaluations',[])
  if quick and quick[0]['cp'] is not None and 150<=quick[0]['cp']<=700:accept(b,'finish')
assert sum(x['challengeType']=='tenMoves' for x in out)>=16
assert sum(x['challengeType']=='finish' for x in out)>=16
(ROOT/'CloudChess/EngineResources/challenge-starts.json').write_text(json.dumps(out,separators=(',',':')))
(ROOT/'reports/challenge-starts.json').write_text(json.dumps({'positions':len(out),'nodesPerCertificate':2000000,'engine':'Stockfish 19 NNUE','kinds':{k:sum(x['challengeType']==k for x in out) for k in ['tenMoves','finish']},'legalGeneration':True},indent=2))
p.stdin.close();p.wait()
