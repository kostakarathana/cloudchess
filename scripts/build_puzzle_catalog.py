"""Build a reproducible, independently re-certified offline composition bank.
No source game positions enter the app; inputs are Chess Lab's generated motifs.
Changing dimensions is a NEW ruleset and always requires a fresh exact proof.
"""
import concurrent.futures, hashlib, json, random, sqlite3, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'chess-lab'),str(ROOT/'CloudChess/scripts')]
import chess
from rectangular_chess import RectBoard

def tags_for(fen,line,c,r,mate):
    b=chess.Board(fen) if (c,r)==(8,8) else RectBoard(fen,c,r)
    tags=set(['plan:mate'+('4plus' if mate>=4 else str(mate)) if mate else 'plan:improvement'])
    nonpawn=sum({chess.KNIGHT:3,chess.BISHOP:3,chess.ROOK:5,chess.QUEEN:9}.get(pc.piece_type,0) for pc in b.piece_map().values())
    tags.add('phase:endgame' if nonpawn<=20 or len(b.piece_map())<=10 else 'phase:middlegame')
    if b.is_check():tags.add('inCheck')
    if mate:tags.add('conversion')
    if any(pc.piece_type!=chess.KING and b.is_pinned(pc.color,sq) for sq,pc in b.piece_map().items()):tags.add('absolutePin')
    names=chess.PIECE_NAMES
    for i,uci in enumerate(line):
        m=chess.Move.from_uci(uci);assert m in b.legal_moves
        p=b.piece_at(m.from_square);capture=b.is_capture(m)
        old=set(b.attacks(m.from_square));ep=b.is_en_passant(m)
        b.push(m)
        if i%2==0:
            if i==0:tags.add('first:'+names[p.piece_type])
            if capture:tags.add('capture')
            if ep:tags.add('enPassant')
            if b.is_check():tags.add('check')
            elif not capture:tags.add('quietMove')
            if m.promotion:
                tags.add('promotion')
                if m.promotion!=chess.QUEEN:tags.add('underPromotion')
            if len(b.checkers())>1:tags.add('doubleCheck')
            if any(sq!=m.to_square for sq in b.checkers()):tags.add('discoveredCheck')
            targets={sq for sq in b.attacks(m.to_square) if b.piece_at(sq) and b.piece_at(sq).color!=p.color and b.piece_at(sq).piece_type!=chess.PAWN}
            if len(targets)>=2 and targets-old:
                tags|={'fork','fork:'+names[b.piece_at(m.to_square).piece_type]}
                if {chess.KING,chess.QUEEN}.issubset({b.piece_type_at(sq) for sq in targets}):tags.add('royalFork')
    return sorted(tags)

def build_shape(args):
    c,r,pool,ratings=args; rng=random.Random(3000+c*100+r);rng.shuffle(pool)
    proc=subprocess.Popen(['/tmp/cloudchess-puzzle-proof'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
    out=[];seen=set();counts={k:0 for k in range(1,6)};tries=0
    quota=160 if c==r and c>=5 else 32
    for p in pool:
        proof=p['proof'];mate=proof.get('mate',1 if p['generator']=='motif-v1' else 0)
        group=min(mate,4) if mate else 5
        if counts[group]>=quota:continue
        board=chess.Board(p['fen']);coords=[(chess.square_file(sq),chess.square_rank(sq),pc) for sq,pc in board.piece_map().items()]
        # Translate a generated motif into the target extent, including old edges.
        minf=min(x for x,y,pc in coords);maxf=max(x for x,y,pc in coords)
        minr=min(y for x,y,pc in coords);maxr=max(y for x,y,pc in coords)
        if maxf-minf>=c or maxr-minr>=r:continue
        offsets=[(0,0)] if p['size']==c==r else [(dx,dy) for dx in range(-minf,c-maxf) for dy in range(-minr,r-maxr)]
        rng.shuffle(offsets)
        for dx,dy in offsets[:2]:
            b=chess.Board(None);b.turn=board.turn
            for x,y,pc in coords:b.set_piece_at(chess.square(x+dx,y+dy),pc)
            fen=b.fen();key=(fen,c,r)
            if key in seen:continue
            tries+=1
            request=dict(initial=fen,columns=c,rows=r,mate=mate,gain=proof.get('gain',2),plies=proof.get('plies',4),operation='certify',budget=160000 if p['size']==c==r else 18000)
            proc.stdin.write(json.dumps(request)+'\n');proc.stdin.flush();result=json.loads(proc.stdout.readline())
            if 'error' in result:continue
            try:tags=tags_for(fen,result['line'],c,r,mate)
            except AssertionError:raise RuntimeError(('Rules disagree',request,result))
            seen.add(key);meta=ratings.get(p['id'],{})
            ident=hashlib.sha256(f'{c}x{r}:{fen}'.encode()).hexdigest()[:24]
            out.append(dict(id=ident,fen=fen,columns=c,rows=r,mate=mate,gain=request['gain'],plies=2*mate-1 if mate else request['plies'],rating=meta.get('rating',800+mate*150),uncertainty=meta.get('uncertainty',650),complexity=meta.get('complexity',50),seconds=meta.get('seconds',45),tags=tags,line=result['line'],source=p['id'],nodes=result['nodes']))
            counts[group]+=1;break
        if min(counts.values())>=quota:break
    proc.terminate();print(f'{c}x{r}: {len(out)}, groups {counts}, candidates {tries}',flush=True)
    if not out:raise RuntimeError(f'Empty shape {c}x{r}')
    return out

if __name__=='__main__':
    db=sqlite3.connect(ROOT/'chess-lab/data/puzzles.sqlite3')
    pool=[json.loads(row[0]) for row in db.execute("SELECT payload FROM puzzles WHERE origin='generated'")]
    pool=[p for p in pool if p['proof']['type'] in ('exhaustive-mate-in-one','exhaustive-mate','exhaustive-material')]
    ratings={p['id']:p for p in json.loads((ROOT/'chess-lab/data/adaptive-catalog.json').read_text())}
    with concurrent.futures.ProcessPoolExecutor(max_workers=4) as ex:
        results=list(ex.map(build_shape,[(c,r,pool.copy(),ratings) for c in range(4,9) for r in range(4,9)]))
    out=sorted(sum(results,[]),key=lambda p:p['id'])
    path=ROOT/'CloudChess/CloudChess/EngineResources/puzzles.json';path.write_text(json.dumps(out,separators=(',',':')))
    report=dict(count=len(out),shapes={f'{c}x{r}':sum(p['columns']==c and p['rows']==r for p in out) for c in range(4,9) for r in range(4,9)},certification='Exact all-defenses, unique root move, exact mate distance or material gain surviving final opponent reply',rating='Provisional transfer from existing trained difficulty model; not calibrated Elo',source='Chess Lab generated CC0-derived compositions',sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    (ROOT/'CloudChess/reports/puzzle-catalog.json').write_text(json.dumps(report,indent=2));print(report)
