import json,subprocess,concurrent.futures
from pathlib import Path
import chess
R=Path(__file__).resolve().parents[1]
items=json.loads((R/'CloudChess/EngineResources/challenge-starts.json').read_text())
def verify(item):
 b=chess.Board(item['fen']);assert b.is_valid() and not b.is_game_over()
 cmd=['/tmp/cloudchess-native-engine',str(R/'CloudChess/EngineResources/nn-1a298aa575a0.nnue')]
 raw=subprocess.check_output(cmd,input=json.dumps(dict(action='analyse',initial=item['fen'],nodes=2000000,multipv=1))+'\n',text=True)
 r=json.loads(raw);cp=r['evaluations'][0]['cp'];assert r['limitedStrength']==False
 assert abs(cp)<=10 if item['challengeType']=='tenMoves' else 180<=cp<=650
 assert cp==item['initialEvaluation'],(cp,item['initialEvaluation'])
 for move in r['evaluations'][0]['pv']:
  assert chess.Move.from_uci(move) in b.legal_moves;b.push_uci(move)
 return {'id':item['id'],'kind':item['challengeType'],'cp':cp,'depth':r['evaluations'][0]['depth']}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(verify,items))
print(json.dumps({'status':'passed','positions':len(rows),'checks':len(rows)*4,'evaluations':rows},indent=2))
