"""Reproducible bot-feature training; game-grouped human rating holdout.
Never trains from the old catalog's estimated ratings or puzzle identities.
"""
import os
os.environ['OMP_NUM_THREADS']='2';os.environ['OPENBLAS_NUM_THREADS']='1'
import argparse,concurrent.futures,csv,hashlib,json,subprocess,time
from pathlib import Path
import chess,numpy as np,joblib
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error,r2_score
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'CloudChess/training';BIN='/tmp/cloudchess-difficulty'
def digest(s):return hashlib.sha256(s.encode()).hexdigest()
def collect_rows():
 rows={}
 for name in ['lichess-source.csv','lichess-expansion.csv']:
  with (ROOT/'chess-lab/data'/name).open() as f:
   for r in csv.DictReader(f):
    if int(r['RatingDeviation'])>100 or int(r['NbPlays'])<100 or int(r['Popularity'])<0:continue
    if r['PuzzleId'] in rows:continue
    moves=r['Moves'].split()
    if not 2<=len(moves)<=12:continue
    try:
     b=chess.Board(r['FEN']);b.push_uci(moves[0])
     if b.castling_rights:continue # No silently altered source rules.
     fen=b.fen()
     for m in moves[1:]:b.push_uci(m)
    except ValueError:continue
    group=r['GameUrl'].split('lichess.org/')[-1].split('/')[0].split('#')[0][:8]
    rows[r['PuzzleId']]=dict(id=r['PuzzleId'],fen=fen,columns=8,rows=8,line=moves[1:],rating=int(r['Rating']),group=group,bucket=int(digest(group)[:8],16)%100)
 return sorted(rows.values(),key=lambda r:digest(r['id']))[:60000]
def features(chunk):
 p=subprocess.Popen([BIN],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1);out=[]
 try:
  for q in chunk:
   p.stdin.write(json.dumps(q)+'\n');p.stdin.flush();r=json.loads(p.stdout.readline());assert 'error' not in r,(q,r)
   out.append(dict(q,measurement=r))
 finally:p.terminate();p.wait()
 return out

def collect():
 start=time.time();manifest=json.loads((OUT/'measurement-manifest.json').read_text());assert manifest['featureImplementationSHA256']==hashlib.sha256((ROOT/'CloudChess/NativeEngine/PuzzleDifficulty.hpp').read_bytes()).hexdigest(),'Feature cache version mismatch'
 for name,expected in manifest['sourceFiles'].items():assert hashlib.sha256((ROOT/'chess-lab/data'/name).read_bytes()).hexdigest()==expected,'Source cache version mismatch'
 rows=collect_rows();print('Eligible sampled human-rated puzzles',len(rows),flush=True)
 bank=json.loads((ROOT/'CloudChess/CloudChess/EngineResources/puzzles.json').read_text())
 for name,data in [('human',rows),('generated',bank)]:
  path=OUT/(name+'-measurements.jsonl');existing={}
  if path.exists():
   for line in path.read_text().splitlines():r=json.loads(line);existing[r['id']]=r
  missing=[p for p in data if p['id'] not in existing]
  print(name,'cached',len(existing),'remaining',len(missing),flush=True)
  with path.open('a') as f,concurrent.futures.ProcessPoolExecutor(max_workers=6) as pool:
   futures=[pool.submit(features,missing[i:i+100]) for i in range(0,len(missing),100)]
   count=0
   for future in concurrent.futures.as_completed(futures):
    result=future.result()
    for r in result:f.write(json.dumps(r,separators=(',',':'))+'\n')
    f.flush();count+=len(result)
    if count%2000==0:print(name,count,'elapsed',round(time.time()-start,1),flush=True)
 print('Collection seconds',round(time.time()-start,1),flush=True)

def fit():
 rows=sorted([json.loads(l) for l in (OUT/'human-measurements.jsonl').read_text().splitlines()],key=lambda r:r['id'])
 x=np.array([r['measurement']['features'] for r in rows],dtype=np.float32).astype(np.float64);y=np.array([r['rating'] for r in rows]);bucket=np.array([r['bucket'] for r in rows]);train=bucket<70;cal=(bucket>=70)&(bucket<85);test=bucket>=85
 for a,b in [(train,cal),(cal,test),(train,test)]:assert not ({rows[i]['group'] for i in np.where(a)[0]}&{rows[i]['group'] for i in np.where(b)[0]})
 # Remove exact position leakage even when it occurred in different games.
 key=lambda r:' '.join(r['fen'].split()[:4])
 train_positions={key(rows[i]) for i in np.where(train)[0]}
 cal &= np.array([key(r) not in train_positions for r in rows])
 calibration_positions={key(rows[i]) for i in np.where(cal)[0]}
 test &= np.array([key(r) not in train_positions|calibration_positions for r in rows])
 # Fixed hyperparameters; evaluation set never controls model selection.
 def reg():return HistGradientBoostingRegressor(max_iter=260,max_leaf_nodes=23,learning_rate=.07,l2_regularization=12,min_samples_leaf=35,random_state=822,early_stopping=False)
 model=reg().fit(x[train],y[train]);base=reg().fit(x[train,:31],y[train]);pred=model.predict(x[test]);err=np.abs(y[cal]-model.predict(x[cal]));radius=float(np.quantile(err,.8))
 report=dict(version='challenge-v2',humanExamples=len(rows),train=int(train.sum()),calibration=int(cal.sum()),test=int(test.sum()),features=x.shape[1],trees=model.n_iter_,mae=float(mean_absolute_error(y[test],pred)),structuralOnlyMAE=float(mean_absolute_error(y[test],base.predict(x[test,:31]))),medianBaselineMAE=float(mean_absolute_error(y[test],np.full(test.sum(),np.median(y[train])))),r2=float(r2_score(y[test],pred)),interval80=radius,coverage80=float(np.mean(abs(pred-y[test])<=radius)),split='SHA256 source game: 70% training, 15% calibration, 15% untouched test; disjoint games',limits='Human-rated orthodox puzzles anchor the scale. Generated/rectangular human difficulty remains a transfer estimate; limited-search bot success is not human Elo.')
 assert report['mae']<report['medianBaselineMAE']*.75,report
 report['numericContract']='Features quantized to float32 before training and native inference; double tree thresholds/accumulation'
 report['exactPositionLeakageRemoved']=int(len(rows)-train.sum()-cal.sum()-test.sum())
 report['heldoutErrorQuantiles']=np.quantile(abs(pred-y[test]),[.5,.8,.95]).tolist()
 names=rows[0]['measurement']['names'];joblib.dump(dict(model=model,names=names,radius=radius),OUT/'difficulty-v2.joblib',compress=3)
 # Export exact native inference from sklearn numeric splits; no Python in app.
 allnodes=[];roots=[]
 for iteration in model._predictors:
  for tree in iteration:
   offset=len(allnodes);roots.append(offset)
   for n in tree.nodes:
    assert not n['is_categorical']
    allnodes.append((int(n['feature_idx']),float(n['num_threshold']),float(n['value']),offset+int(n['left']),offset+int(n['right']),int(n['is_leaf'])))
 header=['// Generated by train_challenge_difficulty.py; do not hand edit.','#pragma once','#include <vector>','namespace ChallengeModel {',f'constexpr double intercept={float(model._baseline_prediction[0,0]):.17g};',f'constexpr double residual80={radius:.17g};','struct Node {int feature;double threshold,value;int left,right,leaf;};','constexpr Node nodes[]={']
 header += ['{%d,%.17g,%.17g,%d,%d,%d},'%n for n in allnodes]
 header += ['};','constexpr int roots[]={'+','.join(map(str,roots))+'};','inline double predict(const std::vector<double>&x){double y=intercept;for(int root:roots){int i=root;while(!nodes[i].leaf){const auto &n=nodes[i];i=double(float(x[n.feature]))<=n.threshold?n.left:n.right;}y+=nodes[i].value;}return y;}','}']
 path=ROOT/'CloudChess/NativeEngine/PuzzleDifficultyModel.hpp';path.write_text('\n'.join(header)+'\n');report['modelSHA256']=digest(path.read_text());report['measurementManifest']=json.loads((OUT/'measurement-manifest.json').read_text())
 report['featureImportancePermutation']={}
 rng=np.random.default_rng(44)
 for label,cols in [('botMeasurements',list(range(31,x.shape[1]))),('solutionLength',[15,16]),('quietSacrifice',[25,26]),('branching',[18,19,20,21,22])]:
  z=x[test].copy();idx=rng.permutation(len(z));z[:,cols]=z[idx][:,cols];report['featureImportancePermutation'][label]=float(mean_absolute_error(y[test],model.predict(z))-report['mae'])
 generated=[json.loads(l) for l in (OUT/'generated-measurements.jsonl').read_text().splitlines()];gx=np.array([r['measurement']['features'] for r in generated],dtype=np.float32).astype(np.float64);gp=model.predict(gx)
 # Catalog includes conservative transfer uncertainty and model provenance.
 updated=[]
 for r,rating in zip(generated,gp):
  p={k:v for k,v in r.items() if k!='measurement'};p['rating']=round(np.clip(rating,400,3000));p['uncertainty']=round(radius*(1 if p['columns']==p['rows']==8 else 1.35));p['difficultyVersion']='challenge-v2';p['botSuccess']=r['measurement']['success'];p['complexity']=round(min(100,10+10*np.log2(1+r['measurement']['features'][18])+8*r['measurement']['features'][15]+4*r['measurement']['features'][25]));p['seconds']=round(10+10*r['measurement']['features'][15]+.5*p['complexity']);updated.append(p)
 (OUT/'recalibrated-puzzles.json').write_text(json.dumps(sorted(updated,key=lambda p:p['id']),separators=(',',':')))
 report['generatedExamples']=len(updated);report['ratingQuantiles']=np.quantile([p['rating'] for p in updated],[0,.1,.5,.9,1]).tolist()
 (ROOT/'CloudChess/reports/difficulty-v2-training.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
 # Export a disjoint source holdout for exact C++/Python parity checks.
 probes=[dict(id=rows[i]['id'],features=x[i].tolist(),prediction=float(model.predict(x[i:i+1])[0])) for i in np.where(test)[0][::max(1,int(test.sum())//256)]]
 (OUT/'inference-parity.json').write_text(json.dumps(probes))
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--fit-only',action='store_true');a=parser.parse_args()
 if not a.fit_only:collect()
 fit()
