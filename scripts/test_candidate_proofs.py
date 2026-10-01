"""Exact candidate grading vs independent legal checkmates and cached full winner sets."""
import json,random,time
from pathlib import Path
from test_puzzle_engine import Engine,board,request,variant,BANK
rng=random.Random(924);e=Engine();checks=alternatives=0;start=time.time()
try:
 for c in range(4,9):
  for h in range(4,9):
   roots=[p for p in BANK if p['columns']==c and p['rows']==h and p['mate'] in [1,2,3]]
   rng.shuffle(roots)
   for p in roots[:12]:
    p=variant(p,rng.randrange(4));history=[]
    while True:
     g=e.call(request(p,'guide',history));assert 'error' not in g,g
     if g['solved']:break
     if 'winning' not in g:history.append(g['line'][0]);continue
     b=board(p,g['fen']);winners=set(g['winning']);alternatives+=len(winners)>1
     for move in b.legal_moves:
      judged=e.call(dict(request(p,'judge',history),candidate=move.uci(),budget=1000000))
      assert 'error' not in judged,(p,history,move,judged)
      assert judged['accepted']==(move.uci() in winners),(p,history,move,judged,g)
      checks+=1
      if g['remaining']==1:
       b.push(move);mate=b.is_checkmate();b.pop()
       assert judged['accepted']==mate;checks+=1
     history.append(sorted(winners)[-1])
 # A material puzzle accepts immediate mate as a better alternative.
 p=dict(fen='8/8/8/2k1K3/3NP3/1p1P4/8/2n5 b - - 0 1',columns=5,rows=5,mate=0,gain=2,plies=4)
 assert e.call(dict(request(p,'judge'),candidate='c1d3'))['accepted'];checks+=1
 p=next(p for p in BANK if p['mate']==4)
 unknown=e.call(dict(request(p,'judge'),candidate=p['line'][0],budget=1))
 assert unknown.get('unknown') and 'accepted' not in unknown;checks+=1
 assert alternatives>20,alternatives
 out=dict(status='passed',candidateChecks=checks,positionsWithAlternatives=alternatives,allShapes=25,seconds=round(time.time()-start,2))
 Path('CloudChess/reports/candidate-proofs-v3.json').write_text(json.dumps(out,indent=2));print(out)
finally:e.close()
