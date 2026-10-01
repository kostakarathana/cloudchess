import csv,json,subprocess,random,os
from pathlib import Path
import chess
R=Path(__file__).resolve().parents[1]
rows=[]
with (R.parent/'chess-lab/data/lichess-expansion.csv').open() as f:
 for r in csv.DictReader(f):
  if int(r['Rating'])>=2400 and ('mateIn2' in r['Themes'] or 'mateIn3' in r['Themes']):rows.append(r)
random.Random(613).shuffle(rows);rows=rows[:30];assert len(rows)==30
p=subprocess.Popen([os.environ.get('CC_ENGINE_BINARY','/tmp/cloudchess-native-engine-next'),str(R/'CloudChess/EngineResources/nn-1a298aa575a0.nnue')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
results=[]
for r in rows:
 b=chess.Board(r['FEN']);moves=r['Moves'].split();b.push_uci(moves[0]);limit=2 if 'mateIn2' in r['Themes'] else 3
 p.stdin.write(json.dumps(dict(action='analyse',initial=b.fen(),nodes=2000000,multipv=1))+'\n');p.stdin.flush();v=json.loads(p.stdout.readline());e=v['evaluations'][0]
 result={'id':r['PuzzleId'],'humanPuzzleRating':int(r['Rating']),'mate':e['mate'],'depth':e['depth'],'matchesHumanSolution':e['pv'][0]==moves[1]}
 assert e['mate'] is not None and 0<e['mate']<=limit,result
 for move in e['pv']:b.push_uci(move)
 assert b.is_checkmate(),result
 results.append(result)
p.stdin.close();p.wait()
print(json.dumps({'status':'passed','positions':len(results),'results':results,'note':'High-rated tactical regression, not a measured game Elo claim.'},indent=2))
