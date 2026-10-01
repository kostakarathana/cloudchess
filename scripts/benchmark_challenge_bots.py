"""Independent full-puzzle matches, with exact adversarial replies.
Bots receive only the current position, never a solution or puzzle objective.
Any proof-valid alternative wins; unknown proof budgets are reported separately.
"""
import concurrent.futures,hashlib,json,random,subprocess,time,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];sys.path[:0]=[str(ROOT/'chess-lab'),str(ROOT/'CloudChess/scripts')]
from rectangular_chess import RectEngine
from test_puzzle_engine import Engine,request,board
BANK=json.loads((ROOT/'CloudChess/CloudChess/EngineResources/puzzles.json').read_text())

def run_chunk(puzzles):
 proof=Engine();fairy=RectEngine();probe=subprocess.Popen(['/tmp/cloudchess-difficulty'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1);out=[]
 try:
  for p in puzzles:
   for name,depth,budget in [('native-1',1,256),('native-2',2,1400),('native-4',4,6000),('fairy-128',0,128),('fairy-1024',0,1024),('fairy-8192',0,8192)]:
    history=[];status='unknown';decisions=0;depths=[]
    while len(history)<=p['plies']:
     g=proof.call(dict(request(p,'guide',history),budget=1000000))
     if 'error' in g:break
     if g['solved']:status='solved';break
     if g['turn'] != ('white' if p['fen'].split()[1]=='w' else 'black'):
      history.append(g['line'][0]);continue
     if depth:
      probe.stdin.write(json.dumps(dict(fen=g['fen'],columns=p['columns'],rows=p['rows'],botDepth=depth,budget=budget))+'\n');probe.stdin.flush();r=json.loads(probe.stdout.readline());assert 'error' not in r and r['depth']>0,r
      # Seeded tie selection removes UCI alphabet advantage. No answer used.
      best=max(r['scores']);choices=[m for m,s in zip(r['moves'],r['scores']) if s==best];index=int(hashlib.sha256((p['id']+str(len(history))).encode()).hexdigest()[:8],16)%len(choices);move=choices[index];depths.append(r['depth'])
     else:
      lines=fairy.analyse(g['fen'],(p['columns'],p['rows']),nodes=budget,depth=12,multipv=1);assert lines,(p,g)
      move=lines[0]['pv'][0];depths.append(lines[0]['depth'])
     assert move in g['legal'],(name,p,move,g)
     decisions+=1
     if move not in g['winning']:status='failed';break
     history.append(move)
    out.append(dict(id=p['id'],bot=name,status=status,decisions=decisions,depths=depths,played=history,shape=f"{p['columns']}x{p['rows']}",mate=p['mate']))
 finally:proof.close();fairy.close();probe.terminate();probe.wait()
 return out
if __name__=='__main__':
 start=time.time();sample=[]
 for c in range(4,9):
  for r in range(4,9):
   for mate in range(5):
    eligible=[p for p in BANK if p['columns']==c and p['rows']==r and min(p['mate'],4)==mate]
    sample+=sorted(eligible,key=lambda p:hashlib.sha256(('arena'+p['id']).encode()).hexdigest())[:4]
 path=ROOT/'CloudChess/training/bot-arena.jsonl'
 with path.open('w') as f,concurrent.futures.ProcessPoolExecutor(max_workers=2) as pool:
  futures=[pool.submit(run_chunk,sample[i:i+10]) for i in range(0,len(sample),10)]
  results=[]
  for future in concurrent.futures.as_completed(futures):
   batch=future.result();results+=batch
   for row in batch:f.write(json.dumps(row)+'\n')
   f.flush()
   if len(results)%300==0:print(len(results),'games',round(time.time()-start,1),'seconds',flush=True)
 summary={}
 for name in sorted(set(r['bot'] for r in results)):
  rows=[r for r in results if r['bot']==name];summary[name]={s:sum(r['status']==s for r in rows) for s in ['solved','failed','unknown']}
 assert len(results)>=3000 and sum(r['status']=='unknown' for r in results)<len(results)*.02
 report=dict(games=len(results),positions=len(sample),seconds=round(time.time()-start,2),bots=summary,method='Full puzzles against an exact all-defenses opponent; fail on first non-winning move, all proven alternatives accepted; fresh hash, single thread, fixed nodes; no human Elo claim')
 (ROOT/'CloudChess/reports/difficulty-bot-arena.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
