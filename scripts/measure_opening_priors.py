"""Shallow position-only book ranking priors. Displayed puzzles are rechecked at 2M nodes."""
import concurrent.futures,json,time
import train_mode_difficulty as m
OUT=m.OUT/'opening-v3-priors.jsonl'
def batch(rows):
 e=m.Engine();out=[]
 try:
  for p in rows:
   state=e.analyse(p['fen'],nodes=30000,multipv=3)
   if not state.get('evaluations'):continue
   q=dict(p,kind='opening',turns=3)
   out.append(dict(id=p['id'],features=m.features(q,state,state['evaluations'],0),nodes=30000))
  return out
 finally:e.close()
if __name__=='__main__':
 done={json.loads(l)['id'] for l in OUT.read_text().splitlines()} if OUT.exists() else set()
 rows=[p for p in json.loads((m.ROOT/'CloudChess/EngineResources/opening-book.json').read_text())['starts'] if p['id'] not in done]
 batches=[rows[i:i+40] for i in range(0,len(rows),40)];count=len(done);start=time.time()
 with OUT.open('a') as f,concurrent.futures.ProcessPoolExecutor(max_workers=2) as pool:
  for values in pool.map(batch,batches):
   for p in values:f.write(json.dumps(p,separators=(',',':'))+'\n')
   f.flush();count+=len(values);print(count,round(time.time()-start),flush=True)
