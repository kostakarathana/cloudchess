"""Independent legality oracle plus the actual native Stockfish grading boundary."""
import json, subprocess, random
from pathlib import Path
import chess
ROOT=Path(__file__).resolve().parents[1]
book=json.loads((ROOT/'CloudChess/EngineResources/opening-book.json').read_text())
p=subprocess.Popen(['/tmp/cloudchess-native-engine',str(ROOT/'CloudChess/EngineResources/nn-1a298aa575a0.nnue')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
checks=0
def call(**r):
 p.stdin.write(json.dumps(r)+'\n');p.stdin.flush();v=json.loads(p.stdout.readline());assert 'error' not in v,v;return v
def score(row):
 if 'mate' in row and row['mate'] is not None:return (100000-row['mate']) if row['mate']>0 else -100000-row['mate']
 return row['cp']
rng=random.Random(42)
for fen,moves in rng.sample(list(book['moves'].items()),2048):
 b=chess.Board(fen+' 0 1');r=call(action='state',initial=b.fen())
 assert set(r['legal'])=={m.uci() for m in b.legal_moves};checks+=1
 for move in moves:assert move in r['legal'];checks+=1
for start in book['starts']:
 assert start['ply']<=6 and chess.Board(start['fen']).is_valid();checks+=1
cases=[([],m,False) for m in ['e2e4','d2d4','c2c4','g1f3']]
cases += [(['e2e4'],m,False) for m in ['e7e5','c7c5','e7e6','c7c6','g8f6']]
cases += [(['f2f3','e7e5'],'g2g4',True),(['e2e4','e7e5','g1f3'],'d8h4',True),(['d2d4','d7d5'],'d1d3',False)]
results=[]
for history,move,reject in cases:
 best=call(action='analyse',moves=history,nodes=2000000,multipv=1)
 played=call(action='analyse',moves=history,root=move,nodes=2000000,multipv=1)
 assert not best['limitedStrength'] and not played['limitedStrength'];checks+=2
 loss=score(best['evaluations'][0])-score(played['evaluations'][0])
 if loss>100:
  best=call(action='analyse',moves=history,nodes=8000000,multipv=1)
  played=call(action='analyse',moves=history,root=move,nodes=8000000,multipv=1)
  loss=score(best['evaluations'][0])-score(played['evaluations'][0])
 assert (loss>100)==reject,(history,move,loss,reject);checks+=1
 assert played['evaluations'][0]['pv'][0]==move;checks+=1
 b=chess.Board()
 for m in history:b.push_uci(m)
 for m in played['evaluations'][0]['pv']:assert chess.Move.from_uci(m) in b.legal_moves;b.push_uci(m);checks+=1
 results.append({'history':history,'move':move,'loss':loss,'rejected':reject})
 print(history,move,loss,flush=True)
p.stdin.close();p.wait(timeout=10)
report={'status':'passed','checks':checks,'native_positions':2048,'cases':results,'source_edges':sum(map(len,book['moves'].values()))}
(ROOT/'reports/native-opening-regression.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
