"""Real mode rollouts against the shipping Stockfish bridge. Human Elo is not assumed.
Game/root-family splits isolate validation. Censored conversions are never failures.
Raw played moves, grades, search budgets and model parity probes are retained.
"""
import os
os.environ['OMP_NUM_THREADS']='2';os.environ['OPENBLAS_NUM_THREADS']='1'
import argparse,concurrent.futures,hashlib,json,math,subprocess,time
from pathlib import Path
import chess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'training';REPORT=ROOT/'reports';NETWORK=ROOT/'CloudChess/EngineResources/nn-1a298aa575a0.nnue'
BIN='/tmp/cloudchess-native-engine'
KINDS=['finish','tenMoves','personal','opening']
NAMES=['finish','tenMoves','personal','opening','pieces','ownMaterial','enemyMaterial','pawns','inCheck','legal','evaluation','secondGap','thirdGap','quiet','turns','gamePly','opponent','solver']
def h(s):return hashlib.sha256(s.encode()).hexdigest()
def cp(e):return (100000-e['mate'] if e['mate']>0 else -100000-e['mate']) if e.get('mate') is not None else e.get('cp',0)
def features(q,state,rows,opponent):
 b=chess.Board(q['fen']);values={1:100,2:320,3:335,4:500,5:900,6:0}
 own=sum(values[p.piece_type] for p in b.piece_map().values() if p.color==b.turn)
 enemy=sum(values[p.piece_type] for p in b.piece_map().values() if p.color!=b.turn)
 scores=[cp(e) for e in rows];best=scores[0];gaps=[min(5,max(0,(best-v)/400)) for v in scores[1:3]]
 gaps += [5]*(2-len(gaps));m=chess.Move.from_uci(rows[0]['pv'][0])
 return [int(q['kind']==k) for k in KINDS]+[len(b.piece_map())/32,own/4000,enemy/4000,chess.popcount(b.pawns)/16,int(b.is_check()),len(state['legal'])/40,max(-2,min(2,best/1000)),*gaps,int(not b.is_capture(m) and not b.gives_check(m)),q['turns']/10,min(40,b.ply())/20,opponent/1000]
class Engine:
 def __init__(self):
  self.p=subprocess.Popen([BIN,str(NETWORK)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1);self.cache={};self.calls=0
 def call(self,**r):
  self.p.stdin.write(json.dumps(r)+'\n');self.p.stdin.flush();v=json.loads(self.p.stdout.readline());assert 'error' not in v,v;self.calls+=1;return v
 def analyse(self,fen,root=None,nodes=2000000,multipv=1):
  key=(fen,root,nodes,multipv)
  if key not in self.cache:
   r=dict(action='analyse',initial=fen,nodes=nodes,multipv=multipv)
   if root:r['root']=root
   self.cache[key]=self.call(**r)
  return self.cache[key]
 def close(self):self.p.stdin.close();self.p.wait(timeout=20)
def jobs():
 book=json.loads((ROOT/'CloudChess/EngineResources/opening-book.json').read_text())
 out=[]
 for p in json.loads((ROOT/'CloudChess/EngineResources/challenge-starts.json').read_text()):
  out.append(dict(id=p['id'],fen=p['fen'],kind=p['challengeType'],turns=20 if p['challengeType']=='finish' else 10,group=p['id']))
 # Distinct ECO families are held out as a unit, not randomly split continuations.
 for i,p in enumerate(sorted(book['starts'],key=lambda p:h('mode-v3'+p['id']))[:96]):
  out.append(dict(id=p['id'],fen=p['fen'],kind='opening',turns=3+i%3,group='eco:'+p['eco']))
 import csv
 seen=set()
 with (ROOT.parent/'chess-lab/data/lichess-expansion.csv').open() as f:
  candidates=sorted(list(csv.DictReader(f)),key=lambda p:h('mode-personal'+p['PuzzleId']))
 for p in candidates:
  if len(seen)>=96:break
  b=chess.Board(p['FEN']);line=p['Moves'].split();b.push_uci(line[0]);key=' '.join(b.fen().split()[:4])
  if key in seen or b.is_game_over() or len(line)<2:continue
  seen.add(key);out.append(dict(id=p['PuzzleId'],fen=b.fen(),kind='personal',turns=min(3,(len(line)-1+1)//2),group='game:'+p['GameUrl'].split('lichess.org/')[-1][:8]))
 return out

def run(q):
 e=Engine()
 try:return rollout(q,e)
 finally:e.close()
def rollout(q,e):
 book=json.loads((ROOT/'CloudChess/EngineResources/opening-book.json').read_text())['moves'];out=[]
 initial=e.analyse(q['fen'],multipv=3);rows=initial.get('evaluations',[])
 if not rows:return []
 for opponent in q.get('opponents',([800,1800] if q['kind'] in ['finish','tenMoves'] else [0])):
  x=features(q,initial,rows,opponent)
  for level in [600,1100,1800,2600]:
   b=chess.Board(q['fen']);side=b.turn;history=[];grades=[];status='censored';initial_cp=cp(e.analyse(b.fen())['evaluations'][0]);checks=0
   for ply in range(200 if q['kind']=='finish' else q['turns']*2):
    if b.is_game_over(claim_draw=True):
     status='solved' if b.outcome(claim_draw=True).winner==side else 'failed';break
    player=b.turn==side
    if player or q['kind'] in ['finish','tenMoves']:
     r=e.call(action='bot',initial=q['fen'],moves=history,nodes=300000,elo=level if player else opponent)
     move=r['bestmove'];assert move in r['legal'];checks+=1
    else:
     best=e.analyse(b.fen());move=best['evaluations'][0]['pv'][0]
     if q['kind']=='opening':
      options=sorted(((m,n) for m,n in book.get(' '.join(b.fen().split()[:4]),{}).items() if chess.Move.from_uci(m) in b.legal_moves),key=lambda a:(-a[1],a[0]))[:5]
      if options:
       candidate=options[int(h(q['id']+str(level)+str(ply))[:8],16)%len(options)][0]
       played=best if candidate==move else e.analyse(b.fen(),root=candidate)
       if cp(best['evaluations'][0])-cp(played['evaluations'][0])<=100:move=candidate
    if player and q['kind'] in ['personal','opening']:
     best=e.analyse(b.fen());played=best if move==best['evaluations'][0]['pv'][0] else e.analyse(b.fen(),root=move)
     loss=cp(best['evaluations'][0])-cp(played['evaluations'][0]);threshold=100 if q['kind']=='opening' else 20
     if q['kind']=='opening' and loss>threshold:
      best=e.analyse(b.fen(),nodes=8000000);played=e.analyse(b.fen(),root=move,nodes=8000000)
      loss=cp(best['evaluations'][0])-cp(played['evaluations'][0])
     grades.append(loss)
     if loss>threshold:status='failed';history.append(move);break
    assert chess.Move.from_uci(move) in b.legal_moves;checks+=1;b.push_uci(move);history.append(move)
    if b.is_game_over(claim_draw=True):
     status='solved' if b.outcome(claim_draw=True).winner==side else 'failed';break
    if player and q['kind'] in ['personal','opening'] and (len(history)+1)//2>=q['turns']:status='solved';break
    if q['kind']=='tenMoves' and len(history)==20:
     final=cp(e.analyse(b.fen())['evaluations'][0])*(1 if b.turn==side else -1)
     status='solved' if final>initial_cp else 'failed';break
   out.append(dict(id=q['id'],kind=q['kind'],group=q['group'],fen=q['fen'],turns=q['turns'],opponent=opponent,solver=level,features=x+[level/1000],status=status,moves=history,losses=grades,checks=checks))
 return out

def collect(workers):
 tasks=jobs();path=OUT/'mode-v3-rollouts.jsonl';done=set()
 if path.exists():
  for l in path.read_text().splitlines():done.add(json.loads(l)['id'])
 remaining=[q for q in tasks if q['id'] not in done];start=time.time();count=0
 (OUT/'mode-v3-manifest.json').write_text(json.dumps({'positions':len(tasks),'featureNames':NAMES,'solverLevels':[600,1100,1800,2600],'opponentLevels':[800,1800],'solverNodes':300000,'oracleNodes':2000000,'openingRecheckNodes':8000000,'engineSHA256':hashlib.sha256(Path(BIN).read_bytes()).hexdigest(),'bridgeSHA256':hashlib.sha256((ROOT/'NativeEngine/ChessBridge.mm').read_bytes()).hexdigest(),'networkSHA256':hashlib.sha256(NETWORK.read_bytes()).hexdigest(),'limits':'Nominal bot levels, not verified human/site Elo. Native Skill randomness is stochastic; raw outcomes retained. Conversion horizon 200 plies; censored excluded.'},indent=2))
 with path.open('a') as f,concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
  futures=[pool.submit(run,q) for q in remaining]
  for fut in concurrent.futures.as_completed(futures):
   rows=fut.result()
   for row in rows:f.write(json.dumps(row,separators=(',',':'))+'\n')
   f.flush();count+=len(rows);print('matches',count,'seconds',round(time.time()-start),flush=True)
 print('collection complete',flush=True)

if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--workers',type=int,default=4);args=a.parse_args();collect(args.workers)
