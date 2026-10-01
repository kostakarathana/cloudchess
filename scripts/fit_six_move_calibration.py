"""Calibrate the existing positional model at six turns without changing other modes.
Uses replayed shipping-bot trajectories, full-history 2M-node endpoint searches,
and the original root-family-disjoint split. No external Python dependencies.
"""
import hashlib,json,math
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
rows=[json.loads(l) for l in (ROOT/'reports/improvement-v16/six-move-outcomes.jsonl').read_text().splitlines()]
def bucket(r):return int(hashlib.sha256(r['group'].encode()).hexdigest()[:8],16)%100
train=[r for r in rows if bucket(r)<70]
cal=[r for r in rows if 70<=bucket(r)<85]
test=[r for r in rows if bucket(r)>=85]
assert min(map(len,[train,cal,test]))>=16
for a,b in [(train,cal),(train,test),(cal,test)]:assert not ({r['group'] for r in a}&{r['group'] for r in b})
def probability(z):return 1/(1+math.exp(-max(-40,min(40,z))))
def metrics(data,scale,bias):
 pairs=[(r['status']=='solved',probability(scale*r['priorLogit']+bias)) for r in data]
 return {'n':len(pairs),'brier':sum((p-y)**2 for y,p in pairs)/len(pairs),'observed':sum(y for y,p in pairs)/len(pairs),'predicted':sum(p for y,p in pairs)/len(pairs)}
# Convex regularized logistic calibration. Positive slope retains monotonic skill
# and opponent relationships. Fixed regularization; untouched test is report-only.
scale,bias=1.,0.
for _ in range(80):
 g0=.03*(scale-1);g1=.03*bias;h00=.03;h01=0.;h11=.03
 for r in train:
  z=r['priorLogit'];p=probability(scale*z+bias);y=r['status']=='solved';w=p*(1-p)/len(train)
  g0+=(p-y)*z/len(train);g1+=(p-y)/len(train);h00+=w*z*z;h01+=w*z;h11+=w
 det=h00*h11-h01*h01
 ds=(h11*g0-h01*g1)/det;db=(-h01*g0+h00*g1)/det
 scale=max(.25,min(3,scale-.5*ds));bias=max(-2,min(2,bias-.5*db))
# Select between identity and fitted adjustment only on the calibration split.
candidate={'scale':scale,'bias':bias,'calibration':metrics(cal,scale,bias)}
if metrics(cal,scale,bias)['brier']>metrics(cal,1,0)['brier']:scale,bias=1.,0.
report={'candidate':candidate,'selected':'identity' if (scale,bias)==(1.,0.) else 'fitted','rawSHA256':hashlib.sha256((ROOT/'reports/improvement-v16/six-move-outcomes.jsonl').read_bytes()).hexdigest(),'version':'mode-bots-v3-six-v1','samples':len(rows),'scale':scale,'bias':bias,'train':metrics(train,scale,bias),'calibration':metrics(cal,scale,bias),'test':metrics(test,scale,bias),'testBefore':metrics(test,1,0),'oracleNodes':2000000,'turns':6,'limits':'Provisional shipping-bot scale, not measured human Elo. Uses first six turns of existing legal bot trajectories; all nonterminal endpoints re-evaluated at full history and 2M requested budget (mate searches may stop early). Existing model root-family split retained. No new player games assumed.'}
path=ROOT/'CloudChess/EngineResources/mode-difficulty-v3.json';model=json.loads(path.read_text());model['improvement']={k:report[k] for k in ['scale','bias','samples']};path.write_text(json.dumps(model,separators=(',',':')))
(ROOT/'reports/improvement-v16/calibration-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
