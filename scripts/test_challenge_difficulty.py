"""Native inference parity, actual-position rating, and generator regression."""
import concurrent.futures,hashlib,json,subprocess,time,sys
from pathlib import Path
import numpy as np,joblib
ROOT=Path(__file__).resolve().parents[2];sys.path[:0]=[str(ROOT/'chess-lab'),str(ROOT/'CloudChess/scripts')]
from test_puzzle_engine import Engine,request,board
BIN='/tmp/cloudchess-difficulty'
class Probe:
 def __init__(self):self.p=subprocess.Popen([BIN],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
 def call(self,q):
  self.p.stdin.write(json.dumps(q)+'\n');self.p.stdin.flush();return json.loads(self.p.stdout.readline())
 def close(self):self.p.terminate();self.p.wait()
def chunk_check(items):
 e=Engine();probe=Probe();checks=0;count=0;deltas=[];latencies=[];nodes=0
 try:
  for p,novel in items:
   start=time.perf_counter();r=e.call(dict(request(p,'certify'),measureDifficulty=True,budget=max(18000,min(160000,p["nodes"]*2+12000)) if novel else 400000));latencies.append(time.perf_counter()-start)
   if 'error' in r:
    assert novel,(p,r);checks+=1;continue
   d=r['difficulty'];assert d['version']=='challenge-v2';assert 400<=d['rating']<=3000 and 0<d['uncertainty']<1000 and 0<d['complexity']<=100
   b=board(p)
   for m in r['line']:assert m in {m.uci() for m in b.legal_moves};b.push_uci(m);checks+=1
   assert b.is_checkmate() if p['mate'] else not b.is_game_over()
   measured=probe.call(dict(p,line=r['line']));assert 'error' not in measured
   prediction=probe.call({'features':measured['features']})['prediction']
   assert abs(d['rating']-min(3000,max(400,prediction)))<=.501
   assert np.allclose(d['botSuccess'],measured['success'],atol=1e-12)
   assert all(np.isfinite(measured['features'])) and d['probeNodes']<=3*(257+1401+6001)
   nodes+=d['probeNodes'];checks+=6
   if novel:deltas.append(d['rating']-p['rating']);count+=1
   else:assert d['rating']==p['rating'];checks+=1
 finally:e.close();probe.close()
 return dict(checks=checks,novel=count,deltas=deltas,latencies=latencies,nodes=nodes)
if __name__=='__main__':
 start=time.time();probe=Probe();parity=json.loads((ROOT/'CloudChess/training/inference-parity.json').read_text());errors=[]
 for p in parity:errors.append(abs(probe.call({'features':p['features']})['prediction']-p['prediction']))
 assert max(errors)<1e-8;probe.close()
 bank=json.loads((ROOT/'CloudChess/CloudChess/EngineResources/puzzles.json').read_text());proposals=json.loads((ROOT/'CloudChess/training/variant-proposals.json').read_text())
 novel=sorted(proposals,key=lambda p:hashlib.sha256(p['id'].encode()).hexdigest())[:4000]
 items=[(p,False) for p in bank]+[(p,True) for p in novel];results=[]
 with concurrent.futures.ProcessPoolExecutor(max_workers=4) as ex:
  for r in ex.map(chunk_check,[items[i::4] for i in range(4)]):results.append(r)
 changes=[d for r in results for d in r['deltas']];latencies=[v for r in results for v in r['latencies']]
 assert sum(r['novel'] for r in results)>1000
 assert sum(abs(d)>100 for d in changes)>50,'Novel difficulty must respond to actual board changes'
 report=dict(status='passed',checks=len(parity)+sum(r['checks'] for r in results),bankPositions=len(bank),proposals=len(novel),certifiedNovel=sum(r['novel'] for r in results),nativePythonMaxError=max(errors),botSearchNodes=sum(r['nodes'] for r in results),changedByOver100=sum(abs(d)>100 for d in changes),newRatingDeltaQuantiles=np.quantile(changes,[0,.1,.5,.9,1]).tolist(),certificateAndMeasurementLatencySeconds=np.quantile(latencies,[.5,.95,.99,1]).tolist(),seconds=time.time()-start)
 (ROOT/'CloudChess/reports/difficulty-v2-native-tests.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
