#!/usr/bin/env python3
"""Independent python-chess oracle for the in-app C++ chess boundary."""
import os,json,random,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'chess-lab'))
import chess
from chesslab.tags import annotate
p=subprocess.Popen([os.environ.get('CC_ENGINE_BINARY','/tmp/cloudchess-native-engine'),str(ROOT/'CloudChess/EngineResources/nn-1a298aa575a0.nnue')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
def request(value):
 p.stdin.write(json.dumps(value)+'\n');p.stdin.flush();line=p.stdout.readline();assert line,line
 result=json.loads(line);assert 'error' not in result,result;return result
checks=0
for seed in range(1600):
 rng=random.Random(seed);board=chess.Board();san=[];moves=[]
 for _ in range(seed%130):
  if board.is_game_over():break
  m=rng.choice(list(board.legal_moves));san.append(board.san(m));moves.append(m.uci());board.push(m)
 result=request({'action':'state','moves':moves})
 assert set(result['legal'])=={m.uci() for m in board.legal_moves},(seed,result,board.fen())
 assert result['fen'].split(' ')[:3]==board.fen().split(' ')[:3]
 assert result['check']==board.is_check()
 assert result['san']==san,(seed,result['san'],san)
 parsed=request({'action':'parse','moves':san})
 assert parsed['moves']==moves
 checks+=5
 if not board.is_game_over():
  pv=[];b=board.copy()
  for _ in range(7):
   if b.is_game_over():break
   m=rng.choice(list(b.legal_moves));pv.append(m.uci());b.push(m)
  tags=set(request({'action':'tags','moves':moves,'pv':pv})['tags'])
  expected={t['id'] for t in annotate(board.fen(),pv)}
  selected={t for t in expected if t in {'fork','royalFork','doubleCheck','discoveredCheck','absolutePin','promotion','underPromotion','enPassant','castling','scholarsMate','foolsMate','checkmate','mateIn1','inCheck','quietMove','capture','check'} or t.startswith(('fork:','first:'))}
  assert tags==selected,(seed,tags^selected,board.fen(),pv)
  checks+=1
for history in [['f2f3','e7e5','g2g4'],['e2e4','e7e5','f1c4','b8c6','d1h5','g8f6']]:
 result=request({'action':'analyse','moves':history,'nodes':30000,'multipv':1})
 row=result['evaluations'][0];assert row['mate']==1
 board=chess.Board()
 for m in history:board.push_uci(m)
 board.push_uci(row['pv'][0]);assert board.is_checkmate();checks+=2
p.stdin.close();p.wait(timeout=10)
print(json.dumps({'positions':1600,'checks':checks,'status':'passed'}))
