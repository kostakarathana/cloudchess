#!/usr/bin/env python3
"""Play-on puzzle rules through the shipping CCPuzzle entrypoint (CC_PUZZLE_BINARY).
Wrong moves stay on the board and are answered; only the horizon grades.
"""
import json,os,random,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
bank=json.loads((ROOT/'CloudChess/EngineResources/puzzles.json').read_text())
proof=subprocess.Popen([os.environ['CC_PUZZLE_BINARY']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
def call(r):
    proof.stdin.write(json.dumps(r)+"\n");return json.loads(proof.stdout.readline())
def req(p,op,moves,**kw):
    d={"action":"puzzle","operation":op,"initial":p["fen"],"columns":p["columns"],"rows":p["rows"],"mate":p["mate"],"gain":p["gain"],"plies":p["plies"],"moves":moves}
    if p["mate"]==0: d["successGain"]=1
    d.update(kw);return d
checks=0
def check(ok,why):
    global checks
    if not ok: raise SystemExit("FAIL: "+why)
    checks+=1
random.seed(20261104);worst=0.0;played=0
groups={}
for p in bank: groups.setdefault(p["mate"],[]).append(p)
for mate,ps in sorted(groups.items()):
    for p in random.sample(ps,min(60,len(ps))):
        horizon=2*mate-1 if mate else p["plies"]
        root=call(req(p,"position",[]))
        wrong=[m for m in root["legal"] if m!=p["line"][0]]
        for m in random.sample(wrong,min(2,len(wrong))):
            t=time.time();j=call(req(p,"judge",[],candidate=m,budget=1000000));worst=max(worst,time.time()-t)
            if "error" in j: check(j.get("unknown")==True,"Only budget exhaustion may leave a move unknown");continue
            if j["accepted"]: continue
            after=call(req(p,"position",[m]))
            if after["result"] is not None or after["solved"] or horizon==1: continue
            check(isinstance(j.get("refutation"),str) and j["refutation"] in after["legal"],f"Rejected move has a legal escaping defense {p['id']} {m}")
            if mate:
                sv=call(req(p,"solvable",[m,j["refutation"]],budget=1000000))
                check(sv.get("forced")==False or sv.get("unknown")==True,f"After the escaping defense no mate remains {p['id']}")
                g=call(req(p,"guide",[m]))
                check(g.get("forced")==False and g["line"][0] in after["legal"],"Off-track guide answers with a legal defense")
            hist=[m,j["refutation"] if mate else call(req(p,"guide",[m]))["line"][0]]
            # Play on to the horizon with the off-track guide for both sides.
            while len(hist)<horizon:
                pos=call(req(p,"position",hist))
                if pos["result"] is not None or pos["solved"]: break
                t=time.time();g=call(req(p,"guide",hist));worst=max(worst,time.time()-t)
                check("error" not in g,f"Off-track guide never errors before the horizon {p['id']} {hist} {g.get('error')}")
                nxt=(g.get("line") or [None])[0]
                if nxt is None:
                    check(mate>0 and pos["turn"]==("white" if p["fen"].split()[1]=="w" else "black") and g["winning"]==[],"Only an unforced mate attacker has no line")
                    nxt=pos["legal"][0]
                check(nxt in pos["legal"],"Guide move is legal")
                hist.append(nxt)
            end=call(req(p,"position",hist));played+=1
            if mate and end["solved"]: check(end["result"]=="Checkmate","Mate success is an actual mate")
            if not mate and len(hist)==horizon and end["result"] is None:
                side=p["fen"].split()[1]=="w";start=sum({"p":1,"n":3,"b":3,"r":5,"q":9}.get(c.lower(),0)*(1 if c.isupper()==side else -1) for c in p["fen"].split()[0])
                now=sum({"p":1,"n":3,"b":3,"r":5,"q":9}.get(c.lower(),0)*(1 if c.isupper()==side else -1) for c in end["fen"].split()[0])
                check(end["solved"]==(now>start),f"Improve in x succeeds exactly on a net gain {p['id']} {start}->{now}")
# Every certified start is solvable for play (mate, or a net gain).
for p in random.sample(bank,80):
    sv=call(req(p,"solvable",[],budget=1000000))
    check(sv.get("forced")==True or sv.get("unknown")==True,f"Certified start is solvable {p['id']}")
# The certified line still solves with successGain, and the full gain is still required for certification.
for p in random.sample([q for q in bank if q["mate"]==0],40):
    end=call(req(p,"position",p["line"]))
    check(end["solved"],"Certified improvement line solves")
    c=call(req(p,"certify",[]));check("error" not in c and c["winning"]==[p["line"][0]],"Certification unchanged by successGain")
bad=call(req(bank[0],"position",[],successGain=3))
check("error" in bad,"successGain above the certified gain is rejected")
print(json.dumps({"status":"passed","checks":checks,"playedToHorizon":played,"worstSeconds":round(worst,3)}))
