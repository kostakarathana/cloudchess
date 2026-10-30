#!/usr/bin/env python3
"""Native bounded-search bot arena over puzzles selected by the progression harness.

Mirrors scripts/benchmark_challenge_bots.py for the three native tiers only
(stdlib only: no Fairy-Stockfish, no python-chess). Bots receive only the
current position, never a solution or objective; the exact all-defenses prover
supplies the defense and accepts every proven alternative. A game fails on the
first move outside the proven winning set.

Bot tiers are reproducible search budgets (depth/nodes), not human Elo. The
1,000,000-node guide budget is the arena's oracle only; the app's own
judge/certify budgets are untouched.

Usage:
  benchmark_progression_bots.py <selected.jsonl> <proof-cli> <difficulty-cli> [maxPerBucket=120] [sweep|organic] [results.json]

Scores in the JSONL are points (rating^1.5 per puzzle).
"""
import collections,hashlib,json,subprocess,sys,time

BOTS=[('native-1',1,256),('native-2',2,1400),('native-4',4,6000)]

def buckets_for(kind):
    if kind=='sweep':
        return [(s,s+1e-9,f'score={s}') for s in (0,300000,1000000,3000000,10000000)]
    return [(0,300000,'low'),(300000,2000000,'mid'),(2000000,1e13,'high')]

class Cli:
    def __init__(self,path):
        self.p=subprocess.Popen([path],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
    def call(self,q):
        self.p.stdin.write(json.dumps(q)+'\n');self.p.stdin.flush();s=self.p.stdout.readline()
        assert s,'cli exited'
        return json.loads(s)
    def close(self):
        self.p.terminate();self.p.wait()

def play(proof,probe,p,depth,budget):
    history=[];status='unknown';decisions=0
    solver='white' if p['fen'].split()[1]=='w' else 'black'
    while len(history)<=p['plies']:
        g=proof.call(dict(initial=p['fen'],columns=p['columns'],rows=p['rows'],mate=p['mate'],gain=p['gain'],plies=p['plies'],operation='guide',moves=history,budget=1000000))
        if 'error' in g:break
        if g['solved']:status='solved';break
        if g['turn']!=solver:history.append(g['line'][0]);continue
        r=probe.call(dict(fen=g['fen'],columns=p['columns'],rows=p['rows'],botDepth=depth,budget=budget))
        assert 'error' not in r and r['depth']>0,r
        # Seeded tie selection removes UCI alphabet advantage. No answer used.
        best=max(r['scores']);choices=[m for m,s in zip(r['moves'],r['scores']) if s==best]
        index=int(hashlib.sha256((p['id']+str(len(history))).encode()).hexdigest()[:8],16)%len(choices)
        move=choices[index];assert move in g['legal'],(p['id'],move)
        decisions+=1
        if move not in g['winning']:status='failed';break
        history.append(move)
    return status,decisions

def main():
    rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
    proof_bin,probe_bin=sys.argv[2],sys.argv[3]
    cap=int(sys.argv[4]) if len(sys.argv)>4 else 120
    kind=sys.argv[5] if len(sys.argv)>5 else 'organic'
    result_path=sys.argv[6] if len(sys.argv)>6 else None
    buckets=buckets_for(kind)
    def bucket(score):
        for lo,hi,name in buckets:
            if lo<=score<hi:return name
    seen=set();per=collections.OrderedDict((name,[]) for _,_,name in buckets)
    for r in rows:
        if r.get('review') or r['id'] in seen:continue
        b=bucket(r['score'])
        if b is None or len(per[b])>=cap:continue
        seen.add(r['id']);per[b].append(r)
    proof=Cli(proof_bin);probe=Cli(probe_bin)
    start=time.time();games=0;results={};unknown=0
    try:
        for b,items in per.items():
            results[b]={'count':len(items),'meanRating':sum(i['rating'] for i in items)/max(1,len(items)),'bots':{}}
            for name,depth,budget in BOTS:
                counter=collections.Counter()
                for p in items:
                    status,_=play(proof,probe,p,depth,budget);counter[status]+=1;games+=1
                unknown+=counter['unknown']
                results[b]['bots'][name]={'solved':counter['solved'],'failed':counter['failed'],'unknown':counter['unknown'],'solvedPercent':100*counter['solved']/max(1,len(items))}
    finally:
        proof.close();probe.close()
    seconds=time.time()-start
    print(f"{kind}: games={games} seconds={seconds:.1f}")
    print(f"{'bucket':12s} {'n':>4s} {'meanRating':>10s} | "+" | ".join(f"{n:>8s} solved%" for n,_,_ in BOTS))
    for _,_,b in buckets:
        res=results[b]
        print(f"{b:12s} {res['count']:4d} {res['meanRating']:10.0f} | "+" | ".join(f"{res['bots'][n]['solvedPercent']:6.1f}% ({res['bots'][n]['unknown']} unk)" for n,_,_ in BOTS))
    failures=[];checks=[0]
    def check(condition,message):
        checks[0]+=1
        if not condition:failures.append(message);print('FAIL: '+message)
    check(unknown==0,f'zero unknown proofs expected, got {unknown}')
    names=[b for _,_,b in buckets]
    solved={n:[results[b]['bots'][n]['solvedPercent'] for b in names] for n,_,_ in BOTS}
    if kind=='sweep':
        # Buckets: score 0, 300K, 1M, 3M, 10M points.
        for n in ('native-2','native-4'):
            s=solved[n]
            check(s[0]>=s[2]+15,f'{n}: solved at score 0 ({s[0]:.1f}%) must exceed score 100 ({s[2]:.1f}%) by 15 points')
            check(s[2]>=s[4]+15,f'{n}: solved at score 100 ({s[2]:.1f}%) must exceed score 1000 ({s[4]:.1f}%) by 15 points')
            for i in range(1,len(s)):check(s[i]<=s[i-1]+3,f'{n}: solve rate must not rise across score buckets ({names[i-1]} {s[i-1]:.1f}% -> {names[i]} {s[i]:.1f}%)')
        s=solved['native-1']
        for i in range(1,len(s)):check(s[i]<s[i-1],f'native-1: solve rate must strictly fall across score buckets ({names[i-1]} {s[i-1]:.1f}% -> {names[i]} {s[i]:.1f}%)')
    else:
        s=solved['native-4']
        check(s[0]>s[1]+25,f'native-4: organic low bucket ({s[0]:.1f}%) must exceed mid ({s[1]:.1f}%) by 25 points')
        for n in ('native-1','native-2'):check(solved[n][0]>solved[n][1],f'{n}: organic low bucket must exceed mid ({solved[n][0]:.1f}% vs {solved[n][1]:.1f}%)')
    output={'kind':kind,'games':games,'seconds':seconds,'cap':cap,'bots':[{'name':n,'depth':d,'nodes':b} for n,d,b in BOTS],'guideBudget':1000000,'unknown':unknown,'buckets':names,'results':results,'failures':failures,'checks':checks[0]}
    if result_path:
        with open(result_path,'w') as f:json.dump(output,f,indent=1,sort_keys=True)
    print(f"failures={len(failures)}")
    sys.exit(1 if failures else 0)

if __name__=='__main__':main()
