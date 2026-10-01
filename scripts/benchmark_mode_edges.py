"""Extra endpoint opponents; separate output avoids concurrent writes to the main run."""
import concurrent.futures,json,time
from pathlib import Path
import train_mode_difficulty as m
if __name__=='__main__':
 tasks=[]
 for kind in ['finish','tenMoves']:
  pool=[q for q in m.jobs() if q['kind']==kind]
  for q in sorted(pool,key=lambda q:m.h('edges'+q['id']))[:8]:
   q=dict(q,id=q['id']+'-edges',opponents=[300,2600]);tasks.append(q)
 path=m.OUT/'mode-v3-edge-rollouts.jsonl';done=set()
 if path.exists():done={json.loads(l)['id'] for l in path.read_text().splitlines()}
 with path.open('a') as f,concurrent.futures.ProcessPoolExecutor(max_workers=2) as pool:
  for rows in pool.map(m.run,[q for q in tasks if q['id'] not in done]):
   for r in rows:f.write(json.dumps(r,separators=(',',':'))+'\n')
   f.flush();print('edge matches',len(rows),flush=True)
