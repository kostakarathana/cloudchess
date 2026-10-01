"""Independent python-chess/RectBoard regression for the shipping native prover."""
import concurrent.futures,json,random,subprocess,sys,time,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'chess-lab'),str(ROOT/'CloudChess/scripts')]
import chess
from rectangular_chess import RectBoard
from build_puzzle_catalog import tags_for
BANK=json.loads((ROOT/'CloudChess/CloudChess/EngineResources/puzzles.json').read_text())

class Engine:
 def __init__(self):self.p=subprocess.Popen([os.environ.get('CC_PUZZLE_BINARY','/tmp/cloudchess-puzzle-proof')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
 def call(self,r):
  self.p.stdin.write(json.dumps(r)+'\n');self.p.stdin.flush();s=self.p.stdout.readline();assert s,'Engine crashed';return json.loads(s)
 def close(self):self.p.terminate();self.p.wait()

def board(p,fen=None):return chess.Board(fen or p['fen']) if p['columns']==p['rows']==8 else RectBoard(fen or p['fen'],p['columns'],p['rows'])
def request(p,op='position',moves=None):return dict(initial=p['fen'],columns=p['columns'],rows=p['rows'],mate=p['mate'],gain=p['gain'],plies=p['plies'],operation=op,moves=moves or [])
def variant(p,v):
 b=board(p);out=chess.Board(None);out.turn=b.turn != bool(v&2)
 def sq(s):return chess.square(p['columns']-1-chess.square_file(s) if v&1 else chess.square_file(s),p['rows']-1-chess.square_rank(s) if v&2 else chess.square_rank(s))
 for s,pc in b.piece_map().items():out.set_piece_at(sq(s),chess.Piece(pc.piece_type,pc.color != bool(v&2)))
 return dict(p,fen=out.fen(),line=[chess.Move(sq(chess.Move.from_uci(m).from_square),sq(chess.Move.from_uci(m).to_square),promotion=chess.Move.from_uci(m).promotion).uci() for m in p['line']])

def validate_chunk(chunk):
 e=Engine();checks=0;certified=0;alternate=0;unknown=0
 for original in chunk:
  for v in range(4):
   p=variant(original,v);b=board(p);proof=e.call(request(p,'certify'))
   if proof.get('unknown'):
    # Ordering can change search cost after reflection. Production discards
    # these candidates without showing or grading them; exercise that contract.
    assert v!=0 and 'winning' not in proof and 'solved' not in proof
    unknown+=1;checks+=1;continue
   assert 'error' not in proof,(p,proof)
   assert proof['winning']==[p['line'][0]],(p,proof)
   assert tags_for(p['fen'],proof['line'],p['columns'],p['rows'],p['mate'])==proof['tags'],(p,proof)
   checks+=3;certified+=1
   for m in proof['line']:
    assert chess.Move.from_uci(m) in b.legal_moves,(p,m,b.fen());b.push_uci(m);checks+=1
   final=e.call(request(p,moves=proof['line']));assert final['solved'];checks+=1
   assert b.is_checkmate() if p['mate'] else not b.is_game_over(),(p,final)
   checks+=1
  # Complete solutions while deliberately choosing a different valid solver
  # continuation where one exists. The defense always uses the proof search.
  if original['plies']>1:
   p=original;history=[]
   while True:
    g=e.call(request(p,'guide',history));assert 'error' not in g,(p,history,g)
    if g['solved']:break
    choices=g.get('winning',g['line'][:1]);move=choices[-1]
    alternate+=len(choices)>1;history.append(move);checks+=1
    assert len(history)<=p['plies']
 e.close();return dict(checks=checks,certified=certified,alternatives=alternate,rejectedBudget=unknown)

def random_rules():
 e=Engine();rng=random.Random(44023);checks=0
 for c in range(4,9):
  for r in range(4,9):
   pool=[p for p in BANK if (p['columns'],p['rows'])==(c,r)]
   for i in range(140):
    p=rng.choice(pool);b=board(p)
    for j in range(i%30):
     moves=list(b.legal_moves)
     if not moves:break
     b.push(rng.choice(moves))
    q=dict(p,fen=b.fen());res=e.call(request(q));assert 'error' not in res,(q,res)
    assert set(res['legal'])=={m.uci() for m in b.legal_moves},(c,r,b.fen(),res)
    assert res['check']==b.is_check()
    assert res['fen'].split()[:2]==b.fen().split()[:2];checks+=3
 # Malformed input and exhausted searches must fail closed.
 for fen in ['', '8/8/8/8/8/8/8/8 w - - 0 1','8/8/8/8/8/8/8/K6k w KQ - 0 1','8/8/8/8/8/8/8/K6k w - a3 0 1','8/8/8/8/8/8/8/K5kk w - - 0 1']:
  assert 'error' in e.call(dict(request(BANK[0]),initial=fen));checks+=1
 p=next(p for p in BANK if p['mate']==4)
 assert e.call(dict(request(p,'certify'),budget=1)).get('unknown')==True;checks+=1
 assert 'error' in e.call(dict(request(BANK[0]),moves=['a1a8']));checks+=1
 # Regression: gaining a knight but trading every pawn can leave KB vs K.
 # Material arithmetic alone must never celebrate a dead-position draw.
 dead=dict(initial='8/2B5/8/1p6/1K6/2Pk2n1/8/8 w - - 0 1',columns=7,rows=7,mate=0,gain=2,plies=4,moves=['c7g3','d3c2','b4b5','c2c3'])
 result=e.call(dead);assert result['solved']==False and result['result']=='Draw';checks+=2
 # Checkmate is always a valid improvement, even in a material exercise.
 # This old mini-board fixture has both a gain and a better mating alternative;
 # the stricter generator must reject it as an ambiguous root.
 mate_alternative=dict(initial='8/8/8/2k1K3/3NP3/1p1P4/8/2n5 b - - 0 1',columns=5,rows=5,mate=0,gain=2,plies=4)
 g=e.call(dict(mate_alternative,operation='guide'));assert 'c1d3' in g['winning']
 assert e.call(dict(mate_alternative,moves=['c1d3']))['solved']
 assert 'error' in e.call(dict(mate_alternative,operation='certify'));checks+=3
 e.close();return checks

def independent_proofs():
 """Slow, plain Python AND/OR with NO native evaluation or search code."""
 rng=random.Random(221);pool=BANK.copy();rng.shuffle(pool);tested={0:0,1:0,2:0,3:0,4:0,5:0};nodes=0
 for p in pool:
  if tested[p['mate']]>=24 or p['nodes']>1500:continue
  b=board(p);side=b.turn;values={1:1,2:3,3:3,4:5,5:9,6:0}
  def material(b):return sum(values[pc.piece_type]*(1 if pc.color==side else -1) for pc in b.piece_map().values())
  target=material(b)+p['gain'];memo={}
  def force(b,depth):
   nonlocal nodes
   nodes+=1;key=(b.board_fen(),b.turn,b.ep_square,depth)
   if key in memo:return memo[key]
   if b.is_insufficient_material():return False
   legal=list(b.legal_moves)
   if not legal:return b.turn!=side and b.is_check()
   if depth==0:return bool(not p['mate'] and material(b)>=target)
   own=b.turn==side;answer=not own
   for m in legal:
    b.push(m);value=force(b,depth-1);b.pop()
    if value==own:answer=own;break
   memo[key]=answer;return answer
  winners=[]
  for move in b.legal_moves:
   child=b.copy();child.push(move)
   if force(child,p['plies']-1):winners.append(move.uci())
  assert winners==p['line'][:1],(p,winners)
  if p['mate']>1:assert not force(b,p['plies']-2)
  tested[p['mate']]+=1
 return dict(positions=sum(tested.values()),byMate=tested,nodes=nodes)

if __name__=='__main__':
 start=time.time();rules=random_rules();print('Independent legal rules:',rules,flush=True)
 independent=independent_proofs();print('Independent Python proofs:',independent,flush=True)
 with concurrent.futures.ProcessPoolExecutor(max_workers=4) as ex:
  results=list(ex.map(validate_chunk,[BANK[i::4] for i in range(4)]))
 report=dict(status='passed',rulesChecks=rules,independentProofs=independent,checks=rules+sum(x['checks'] for x in results),certifiedVariations=sum(x['certified'] for x in results),rejectedBudget=sum(x['rejectedBudget'] for x in results),alternativeBranches=sum(x['alternatives'] for x in results),seconds=round(time.time()-start,2))
 (ROOT/'CloudChess/reports/puzzle-engine-tests.json').write_text(json.dumps(report,indent=2));print(report)
