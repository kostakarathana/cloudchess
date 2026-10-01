import concurrent.futures,json,sys,time
from collections import Counter
from test_puzzle_engine import Engine,ROOT,board,request,tags_for

def check_chunk(proposals):
 e=Engine();accepted=0;checks=0;shapes=Counter();reasons=Counter()
 for p in proposals:
  result=e.call(dict(request(p,'certify'),budget=18000))
  if 'error' in result:reasons[result['error']]+=1;continue
  assert len(result['winning'])==1;assert result['line'][0]==result['winning'][0]
  b=board(p)
  for m in result['line']:
   assert m in {m.uci() for m in b.legal_moves};b.push_uci(m);checks+=1
  assert b.is_checkmate() if p['mate'] else not b.is_game_over()
  assert result['tags']==tags_for(p['fen'],result['line'],p['columns'],p['rows'],p['mate'])
  end=e.call(request(p,moves=result['line']));assert end['solved']
  checks+=5;accepted+=1;shapes[f"{p['columns']}x{p['rows']}"]+=1
 e.close();return accepted,checks,shapes,reasons

if __name__=='__main__':
 start=time.time();proposals=json.load(open(sys.argv[1]));unique={p['id']:p for p in proposals}
 shapes=Counter();reasons=Counter();accepted=checks=0
 with concurrent.futures.ProcessPoolExecutor(max_workers=4) as ex:
  for a,c,s,r in ex.map(check_chunk,[list(unique.values())[i::4] for i in range(4)]):accepted+=a;checks+=c;shapes.update(s);reasons.update(r)
 assert accepted>1000 and len(shapes)==25,(accepted,shapes)
 report=dict(status='passed',proposals=len(proposals),unique=len(unique),certified=accepted,checks=checks,shapes=shapes,rejected=reasons,seconds=round(time.time()-start,2))
 (ROOT/'CloudChess/reports/puzzle-composition-tests.json').write_text(json.dumps(report,indent=2));print(report)
