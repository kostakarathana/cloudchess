#!/usr/bin/env python3
"""Adaptive defender (`defend`) through the shipping CCPuzzle entrypoint (CC_PUZZLE_BINARY).

Independent python-chess / RectBoard searches check that:
- strength 1 always picks a best defense: the longest mate resistance, the
  escaping reply off the winning line, or the least material conceded;
- weaker strengths only choose among proven options (a shorter resistance,
  a missed escape, or at most two points conceded, never mate);
- `solverWins` is exact, and replies are deterministic per seed;
- noisy solver bots solve less often as the defender gets stronger.
Run with a Python that has python-chess (e.g. chess-lab/.venv).
"""
import json,os,random,subprocess,sys,time
from functools import lru_cache
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT.parent/'chess-lab'),str(ROOT/'scripts')]
import chess
from rectangular_chess import RectBoard
bank=json.loads((ROOT/'CloudChess/EngineResources/puzzles.json').read_text())
proof=subprocess.Popen([os.environ['CC_PUZZLE_BINARY']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
def call(r):
    proof.stdin.write(json.dumps(r)+"\n");return json.loads(proof.stdout.readline())
def req(p,op,moves,**kw):
    d={"action":"puzzle","operation":op,"initial":p["fen"],"columns":p["columns"],"rows":p["rows"],"mate":p["mate"],"gain":p["gain"],"plies":p["plies"],"moves":moves}
    if p["mate"]==0: d["successGain"]=1
    d.update(kw);return d
def defend(p,moves,strength,seed):return call(req(p,"defend",moves,strength=strength,seed=seed,budget=1000000))
checks=0
def check(ok,why):
    global checks
    if not ok: raise SystemExit("FAIL: "+why)
    checks+=1
VALUES={chess.PAWN:1,chess.KNIGHT:3,chess.BISHOP:3,chess.ROOK:5,chess.QUEEN:9}
def board(p,moves):
    b=chess.Board(p["fen"]) if (p["columns"],p["rows"])==(8,8) else RectBoard(p["fen"],p["columns"],p["rows"])
    for m in moves:b.push(chess.Move.from_uci(m))
    return b
def material(b,side):return sum(VALUES.get(pc.piece_type,0)*(1 if pc.color==side else -1) for pc in b.piece_map().values())
def dead(b):
    """The prover's dead-position rule (PuzzleProof.hpp Board::dead)."""
    minors=knights=0;colors=0
    for sq,pc in b.piece_map().items():
        if pc.piece_type in (chess.PAWN,chess.ROOK,chess.QUEEN):return False
        if pc.piece_type==chess.KNIGHT:minors+=1;knights+=1
        if pc.piece_type==chess.BISHOP:minors+=1;colors|=1<<((chess.square_file(sq)+chess.square_rank(sq))%2)
    return minors<=1 or (not knights and colors!=3)
def key(b,depth):return (b.board_fen(),b.turn,b.ep_square,depth)
class Exact:
    """Independent AND/OR mate distance and material minimax (prover scale)."""
    def __init__(self,p):
        self.p=p;self.attacker=p["fen"].split()[1]=="w";self.mates={};self.values={}
    def mates_in(self,b,depth):
        k=key(b,depth)
        if k in self.mates:return self.mates[k]
        moves=list(b.legal_moves)
        if dead(b):r=False
        elif not moves:r=b.turn!=self.attacker and b.is_check()
        elif depth==0:r=False
        else:
            own=b.turn==self.attacker;r=not own
            for m in moves:
                b.push(m);w=self.mates_in(b,depth-1);b.pop()
                if own and w:r=True;break
                if not own and not w:r=False;break
        self.mates[k]=r;return r
    def distance(self,b,maxdepth):
        for d in range(1 if b.turn==self.attacker else 2,maxdepth+1,2):
            if self.mates_in(b,d):return d
        return -1
    def value(self,b,depth):
        k=key(b,depth)
        if k in self.values:return self.values[k]
        moves=list(b.legal_moves)
        if dead(b):v=-10000
        elif not moves:v=10000 if b.turn!=self.attacker and b.is_check() else -10000
        elif depth==0:v=material(b,self.attacker)
        else:
            own=b.turn==self.attacker;out=[]
            for m in moves:b.push(m);out.append(self.value(b,depth-1));b.pop()
            v=max(out) if own else min(out)
        self.values[k]=v;return v
    def gains(self,b,depth,goal):
        """Play objective for an improvement: any net gain at the horizon, or mate."""
        k=("g",)+key(b,depth)
        if k in self.mates:return self.mates[k]
        moves=list(b.legal_moves)
        if dead(b):r=False
        elif not moves:r=b.turn!=self.attacker and b.is_check()
        elif depth==0:r=material(b,self.attacker)>=goal
        else:
            own=b.turn==self.attacker;r=not own
            for m in moves:
                b.push(m);w=self.gains(b,depth-1,goal);b.pop()
                if own and w:r=True;break
                if not own and not w:r=False;break
        self.mates[k]=r;return r
def horizon(p):return 2*p["mate"]-1 if p["mate"] else p["plies"]
random.seed(20261105);worst=0.0;styles={}
mates=[p for p in bank if 2<=p["mate"]<=3];improvements=[p for p in bank if p["mate"]==0]
# 1. Determinism and the strongest defender on and off the winning line.
for p in random.sample(mates,45)+random.sample(improvements,45):
    exact=Exact(p);root=board(p,[]);depth=horizon(p);goal=material(root,exact.attacker)+1
    first=[p["line"][0]]+random.sample([m.uci() for m in root.legal_moves if m.uci()!=p["line"][0]],min(2,root.legal_moves.count()-1))
    for move in first:
        b=board(p,[move])
        if b.is_game_over() or depth<2:continue
        t=time.time();strong=defend(p,[move],1.0,7);worst=max(worst,time.time()-t)
        if "error" in strong:check(strong.get("unknown")==True,f"Only budget exhaustion is unknown {p['id']} {strong}");continue
        check(defend(p,[move],1.0,7)==strong,"Same request, same reply")
        reply=chess.Move.from_uci(strong["reply"]);check(reply in b.legal_moves,"Reply is legal")
        options={}
        for m in b.legal_moves:
            b.push(m)
            if p["mate"]:options[m.uci()]=(exact.mates_in(b,depth-2),exact.distance(b,depth-2) if exact.mates_in(b,depth-2) else None)
            else:options[m.uci()]=(exact.gains(b,depth-2,goal),exact.value(b,depth-2))
            b.pop()
        wins,metric=options[strong["reply"]]
        check(strong["solverWins"]==wins,f"solverWins is exact {p['id']} {move}")
        if p["mate"]:
            escapes=[m for m,(w,_) in options.items() if not w]
            if escapes:check(not wins,f"Strongest defender escapes when it can {p['id']} {move}")
            else:check(metric==max(d for _,d in options.values()),f"Strongest defender resists longest {p['id']} {move}")
        else:
            check(metric==min(v for _,v in options.values()),f"Strongest defender concedes least {p['id']} {move}")
        # 2. Weaker defenders only choose among proven, bounded options.
        for seed in range(12):
            for strength in (0.0,0.5):
                weak=defend(p,[move],strength,seed)
                if "error" in weak:continue
                styles[(p["mate"]>0,strength,weak["style"])]=styles.get((p["mate"]>0,strength,weak["style"]),0)+1
                w,m=options[weak["reply"]];check(weak["solverWins"]==w,"Weak solverWins is exact")
                if p["mate"]:
                    if weak["style"]=="miss":check(w and any(not x for x,_ in options.values()),"A miss lets a winning line back in")
                    if weak["style"]=="short":check(w and m==min(d for _,d in options.values()),"A short resistance is the shortest")
                else:
                    best=min(v for _,v in options.values())
                    if weak["style"]=="soft":check(best<m<=best+2 and m<10000,"A concession is at most two points, never mate")
                    elif weak["style"]=="miss":check(w and m<10000 and m==min(v for x,v in options.values() if x and v<10000) and not any(x for x,v in options.values() if v==best),"A missed hold is the cheapest reply that lets the gain back in")
                    else:check(m==best,"Otherwise the least material")
# 3. Stronger defenders are harder: noisy solvers play every puzzle to its end.
def solve_rate(sample,strength,accuracy,seed):
    solved=0;rng=random.Random(seed)
    for p in sample:
        hist=[];depth=horizon(p)
        while len(hist)<depth:
            pos=call(req(p,"position",hist))
            if pos["result"] is not None or pos["solved"]:break
            if pos["turn"]==("white" if p["fen"].split()[1]=="w" else "black"):
                g=call(req(p,"guide",hist));good=g.get("winning") or []
                move=rng.choice(good) if good and rng.random()<accuracy else rng.choice(pos["legal"])
            else:
                d=defend(p,hist,strength,rng.getrandbits(31))
                move=d["reply"] if "reply" in d else call(req(p,"guide",hist))["line"][0]
            hist.append(move)
        solved+=call(req(p,"position",hist))["solved"]
    return solved/len(sample)
rates={};started=time.time()
for family,pool in [("mate",[p for p in bank if 2<=p["mate"]<=4]),("improvement",improvements)]:
    sample=random.Random(5).sample(pool,240)
    for strength in (0.0,0.5,1.0):rates[(family,strength)]=solve_rate(sample,strength,0.7,11)
    # Common puzzles and solver seeds; the middle strength may tie within sampling noise.
    check(rates[(family,0.0)]>rates[(family,1.0)]+0.03,f"{family}: the forgiving defender is measurably easier {rates}")
    check(rates[(family,1.0)]-0.02<=rates[(family,0.5)]<=rates[(family,0.0)]+0.02,f"{family}: the middle strength lies between {rates}")
arena=time.time()-started
print(json.dumps({"status":"passed","checks":checks,"worstSeconds":round(worst,3),"arenaSeconds":round(arena,1),
    "styles":{f"{'mate' if k[0] else 'improvement'}@{k[1]}:{k[2]}":v for k,v in sorted(styles.items())},
    "solveRates":{f"{k[0]}@{k[1]}":round(v,3) for k,v in rates.items()}}))
