import os,json,subprocess
from pathlib import Path
import chess
root=Path(__file__).resolve().parents[1]
p=subprocess.Popen([os.environ.get('CC_ENGINE_BINARY','/tmp/cloudchess-native-engine'),str(root/'CloudChess/EngineResources/nn-1a298aa575a0.nnue')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
checks=0
def call(**r):
 p.stdin.write(json.dumps(r)+'\n');p.stdin.flush();v=json.loads(p.stdout.readline());assert 'error' not in v,v;return v
positions=['rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq g3 0 2','7k/8/5KQ1/8/8/8/8/8 w - - 0 1']
for fen in positions:
 before=call(action='analyse',initial=fen,nodes=100000,multipv=1)
 for elo in [400,700,1100,1320,1800,2600,3000]:
  bot=call(action='bot',initial=fen,nodes=100000,multipv=1,elo=elo)
  assert bot['limitedStrength'] and bot['bestmove'] in bot['legal'];checks+=2
  after=call(action='analyse',initial=fen,nodes=100000,multipv=1)
  assert not after['limitedStrength'];assert after['evaluations'][0]==before['evaluations'][0];checks+=2
  b=chess.Board(fen);b.push_uci(after['evaluations'][0]['pv'][0]);assert b.is_checkmate();checks+=1
# Repetition, stalemate, fifty-move draw and insufficient material must stop play.
for fen,moves in [('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1',[]),('7k/8/6K1/8/8/8/8/8 w - - 0 1',[]),('7k/8/5KQ1/8/8/8/8/8 w - - 100 1',[])]:
 r=call(action='analyse',initial=fen,moves=moves,nodes=100000);assert r['result']=='Draw' and 'evaluations' not in r;checks+=2
r=call(action='state',moves=['g1f3','g8f6','f3g1','f6g8']*2);assert r['result']=='Draw';checks+=1
p.stdin.close();p.wait()
print(json.dumps({'status':'passed','checks':checks,'strengthIsolation':True,'terminalRules':True}))
