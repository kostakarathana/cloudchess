"""Bundle verified CC0 sources as a transposition-aware, entirely offline book.
Source observations are NOT engine endorsements; the phone judges every move.
"""
import csv, hashlib, io, json, sqlite3
from collections import defaultdict
from pathlib import Path
import chess, chess.pgn
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT.parent/'chess-lab/data/opening-sources'
OUT=ROOT/'CloudChess/EngineResources'
book=defaultdict(lambda:defaultdict(int));named=0;checks=0
key=lambda b:' '.join(b.fen(en_passant='legal').split()[:4])
for letter in 'abcde':
 for row in csv.DictReader((SOURCE/f'{letter}.tsv').open(),delimiter='\t'):
  game=chess.pgn.read_game(io.StringIO(row['pgn']));assert not game.errors
  b=game.board();named+=1
  for m in game.mainline_moves():
   assert m in b.legal_moves;checks+=1;book[key(b)][m.uci()]+=10;b.push(m)
starts=[]
with sqlite3.connect(f'file:{ROOT.parent}/chess-lab/data/openings.sqlite3?mode=ro',uri=True) as db:
 for payload,screen in db.execute("SELECT payload,screen FROM openings WHERE json_extract(screen,'$.accepted')=1 ORDER BY id"):
  row=json.loads(payload);b=chess.Board();
  for move in row['prefix']:
   m=chess.Move.from_uci(move);assert m in b.legal_moves;checks+=1;b.push(m)
  assert key(b)==key(chess.Board(row['fen']));checks+=1
  for move,count in row['moves'].items():
   assert chess.Move.from_uci(move) in b.legal_moves;checks+=1;book[key(b)][move]+=count
  if row['ply']<=6:
   starts.append(dict(id=row['id'],fen=row['fen'],name=row['family'],eco=row['eco'],ply=row['ply'],visits=row['visits'],rating=row['rating']))
# Every edge is replayed independently, including transposed positions.
for fen,moves in book.items():
 b=chess.Board(fen+' 0 1');assert b.is_valid()
 for move in moves: assert chess.Move.from_uci(move) in b.legal_moves;checks+=1
artifact={'starts':starts,'moves':dict(sorted(book.items()))}
data=json.dumps(artifact,separators=(',',':')).encode();(OUT/'opening-book.json').write_bytes(data)
report={'named_eco_lines':named,'early_starts':len(starts),'unique_positions':len(book),'unique_book_edges':sum(map(len,book.values())), 'legality_checks':checks,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'license':'CC0','source_eco_commit':'c67912be581f0793dbaa776be5ccf111e01f88d9','sources':['https://github.com/lichess-org/chess-openings','https://database.lichess.org/standard/lichess_db_standard_rated_2013-01.pgn.zst'],'scope':'Named ECO continuations plus moves observed at 30,000 engine-screened opening positions. Early drill starts at 2–6 plies. Live Stockfish rechecks starts and all played moves; book membership alone never passes grading.'}
(ROOT/'reports/native-opening-book.json').write_text(json.dumps(report,indent=2))
(OUT/'opening-book-source.json').write_text(json.dumps(report,indent=2))
(OUT/'opening-book-CC0.txt').write_text((SOURCE/'COPYING.txt').read_text())
print(json.dumps(report,indent=2))
