"""Monotone probability model from held-out complete-game/drill bot outcomes."""
import os
os.environ['OMP_NUM_THREADS']='2';os.environ['OPENBLAS_NUM_THREADS']='1'
import json,math,hashlib
from pathlib import Path
import numpy as np
from scipy.optimize import minimize
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import brier_score_loss,log_loss,roc_auc_score
import train_mode_difficulty as source
R=source.ROOT
paths=[R/'training/mode-v3-rollouts.jsonl',R/'training/mode-v3-edge-rollouts.jsonl']
rows=[json.loads(l) for path in paths for l in path.read_text().splitlines()]
known=[r for r in rows if r['status']!='censored']
# Connected components prevent transposed root positions leaking across families.
parent={r['group']:r['group'] for r in known}
def find(x):
 while parent[x]!=x:parent[x]=parent[parent[x]];x=parent[x]
 return x
def union(a,b):
 a,b=find(a),find(b)
 if a!=b:parent[max(a,b)]=min(a,b)
positions={}
for r in known:
 key=' '.join(r['fen'].split()[:4])
 if key in positions:union(r['group'],positions[key])
 else:positions[key]=r['group']
buckets=np.array([int(source.h(find(r['group']))[:8],16)%100 for r in known]);train=buckets<70;cal=(buckets>=70)&(buckets<85);test=buckets>=85
x=np.array([r['features'] for r in known],dtype=float);y=np.array([r['status']=='solved' for r in known],dtype=int)
assert len(known)>=900 and all(m.sum()>=60 for m in [train,cal,test]),(len(known),train.sum(),cal.sum(),test.sum())
for a,b in [(train,cal),(train,test),(cal,test)]:assert not ({find(known[i]['group']) for i in np.where(a)[0]} & {find(known[i]['group']) for i in np.where(b)[0]})
constraints=[0]*len(source.NAMES);constraints[-1]=1;constraints[-2]=-1;constraints[14]=-1
# Fixed hyperparameters, never chosen from the untouched final test partition.
model=HistGradientBoostingClassifier(max_iter=120,max_leaf_nodes=11,min_samples_leaf=24,l2_regularization=10,learning_rate=.055,monotonic_cst=constraints,early_stopping=False,random_state=924).fit(x[train],y[train])
z=model.decision_function(x[cal])
def loss(theta):
 logits=theta[0]*z+theta[1]
 return np.mean(np.logaddexp(0,logits)-y[cal]*logits)+.015*(theta[0]-1)**2+.01*theta[1]**2
platt=minimize(loss,[1.,0.],bounds=[(.25,3),(-2,2)],method='L-BFGS-B').x
pred=1/(1+np.exp(-(model.decision_function(x[test])*platt[0]+platt[1])))
def metrics(mask,p):
 yy=y[test][mask]
 return dict(n=int(mask.sum()),brier=float(brier_score_loss(yy,p[mask])),logLoss=float(log_loss(yy,p[mask],labels=[0,1])),auc=float(roc_auc_score(yy,p[mask])) if len(set(yy))==2 else None,observed=float(np.mean(yy)),predicted=float(np.mean(p[mask])))
report=dict(version='mode-bots-v3',status='measured',matches=len(rows),censored=sum(r['status']=='censored' for r in rows),train=int(train.sum()),calibration=int(cal.sum()),test=int(test.sum()),split='Root position/transposition and game/ECO family disjoint; 70/15/15 by SHA256. Final test never selected hyperparameters.',limits='Nominal shipping bot strengths anchor a training scale. Does not establish human, FIDE, Chess.com or Lichess Elo accuracy. All generated instances retain uncertainty. Conversion runs censored at 200 plies are excluded, not marked losses.',byMode={},solverSuccess={},checks=sum(r['checks'] for r in rows),temperature=platt.tolist())
kindTest=np.array([r['kind'] for r in known])[test]
base=np.zeros(test.sum())
for kind in source.KINDS:
 mask=kindTest==kind
 assert mask.sum()>0,kind
 prior=y[train & (np.array([r['kind'] for r in known])==kind)].mean();base[mask]=prior
 report['byMode'][kind]=metrics(mask,pred)
 report['solverSuccess'][kind]={str(level):{'n':len(a:=[r for r in known if r['kind']==kind and r['solver']==level]),'success':sum(r['status']=='solved' for r in a)/max(1,len(a))} for level in [600,1100,1800,2600]}
report['brier']=float(brier_score_loss(y[test],pred));report['modeOnlyBaselineBrier']=float(brier_score_loss(y[test],base))
assert report['brier']<report['modeOnlyBaselineBrier'],report
nodes=[];roots=[]
for iteration in model._predictors:
 for tree in iteration:
  offset=len(nodes);roots.append(offset)
  for n in tree.nodes:
   assert not n['is_categorical']
   nodes.append(dict(f=int(n['feature_idx']),t=float(n['num_threshold']),v=float(n['value']),l=offset+int(n['left']),r=offset+int(n['right']),leaf=bool(n['is_leaf'])))
export=dict(version='mode-bots-v3',intercept=float(model._baseline_prediction[0,0]),nodes=nodes,roots=roots,temperature=float(platt[0]),bias=float(platt[1]),uncertainty={k:550 for k in source.KINDS},featureNames=source.NAMES)
path=R/'CloudChess/EngineResources/mode-difficulty-v3.json';path.write_text(json.dumps(export,separators=(',',':')))
# Holdout parity vectors also check perspective/geometry extraction separately.
probes=[]
for i in np.where(test)[0]:
 probes.append(dict(fen=known[i]['fen'],kind=known[i]['kind'],features=x[i].tolist(),logit=float(model.decision_function(x[i:i+1])[0]*platt[0]+platt[1])))
(R/'training/mode-v3-parity.json').write_text(json.dumps(probes))
report['modelSHA256']=hashlib.sha256(path.read_bytes()).hexdigest();report['manifest']=json.loads((R/'training/mode-v3-manifest.json').read_text())
(R/'reports/mode-v3-training.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

# Bake independent selection priors, never learner-dependent point values.
# Six anchors interpolate logits identically to the native inference code.
levels=np.array([400.,600.,1100.,1800.,2600.,3000.])
def curves(features):
 return np.array([model.decision_function(np.column_stack([features,np.full(len(features),elo/1000)]))*platt[0]+platt[1] for elo in levels]).T
def quantile(z,value=0):
 out=[]
 for row in z:
  if row[0]>=value:out.append(400.);continue
  if row[-1]<value:out.append(3000.);continue
  i=next(i for i in range(1,6) if row[i]>=value)
  out.append(float(levels[i-1]+(levels[i]-levels[i-1])*(value-row[i-1])/max(1e-10,row[i]-row[i-1])))
 return np.array(out)
path=R/'CloudChess/EngineResources/challenge-starts.json';bank=json.loads(path.read_text())
rootsByID={r['id']:r for r in rows}
for p in bank:
 evidence=rootsByID[p['id']];f=evidence['features'][:-1]
 z=curves(np.array([f]));rating=float(quantile(z)[0]);slope=float((quantile(z,1.0986122887)[0]-quantile(z,-1.0986122887)[0])/2.1972245774)
 p.update(rating=round(rating),difficultyVersion='mode-bots-v3',difficultyFeatures=f,calibrationOpponent=evidence['opponent'],difficultySlope=max(120,min(600,slope)),uncertainty=650 if rating<425 or rating>2975 else 550)
path.write_text(json.dumps(bank,separators=(',',':')))
priors={r['id']:r for r in [json.loads(l) for l in (R/'training/opening-v3-priors.jsonl').read_text().splitlines()]}
path=R/'CloudChess/EngineResources/opening-book.json';book=json.loads(path.read_text());starts=book['starts'];assert all(p['id'] in priors for p in starts)
f=np.array([priors[p['id']]['features'] for p in starts])
for count in [3,4,5]:
 f[:,14]=count/10;ratings=quantile(curves(f))
 for p,rating in zip(starts,ratings):p.setdefault('ratingsByMoves',{})[str(count)]=round(float(rating))
for p in starts:p['rating']=p['ratingsByMoves']['3']
book['difficultyPrior']={'version':'mode-bots-v3','positions':len(starts),'nodes':30000,'purpose':'Selection only; displayed instances always remeasured with full 2M-node MultiPV3 evidence.'}
path.write_text(json.dumps(book,separators=(',',':')))
report['openingRankingPriors']=book['difficultyPrior'];report['edgeMatches']=sum('edges' in r['id'] for r in rows)
report['rawSHA256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
report['uncertaintyMeaning']='550 Elo is a conservative provisional uncertainty floor, not a validated human confidence interval. Boundary estimates use at least 650.'
(R/'reports/mode-v3-training.json').write_text(json.dumps(report,indent=2))
