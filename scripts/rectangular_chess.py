"""Bounded 4..8-file/rank mini chess; orthodox rules remain on 8x8.
Mini pawns move one step, promote at the far edge; no castling or en passant.
Python rules and Fairy-Stockfish independently agree on the legal move set.
"""
import subprocess
from pathlib import Path
import chess
from chesslab.board import MiniBoard
from chesslab.engine import Engine, ENGINE
CONFIG=Path(__file__).with_name('cloud_variants.ini')
BACK={4:'RNQK',5:'RNBQK',6:'RNBQKR',7:'RNBQKNR',8:'RNBQKBNR'}

def dimensions(columns=8,rows=8):
    if type(columns) is not int or type(rows) is not int or not (4<=columns<=8 and 4<=rows<=8):
        raise ValueError('Board dimensions must each be from 4 to 8')
    return columns,rows

def initial_board(columns=8,rows=8):
    dimensions(columns,rows)
    if (columns,rows)==(8,8):return chess.Board()
    board=RectBoard(None,columns,rows)
    for f,symbol in enumerate(BACK[columns]):
        for rank,char in [(0,symbol),(1,'P'),(rows-2,'p'),(rows-1,symbol.lower())]:
            board.set_piece_at(chess.square(f,rank),chess.Piece.from_symbol(char))
    return board

class RectBoard(MiniBoard):
    def __init__(self,fen=None,columns=5,rows=5):
        dimensions(columns,rows)
        self.columns,self.rows,self.size=columns,rows,rows
        self.playable=sum(chess.BB_SQUARES[chess.square(f,r)] for f in range(columns) for r in range(rows))
        chess.Board.__init__(self,fen)
    def copy(self,*,stack=True):
        board=super().copy(stack=stack);board.columns,board.rows=self.columns,self.rows
        return board
    def generate_pseudo_legal_moves(self,from_mask=chess.BB_ALL,to_mask=chess.BB_ALL):
        to_mask &= self.playable
        for move in chess.Board.generate_pseudo_legal_moves(self,from_mask & ~self.pawns & self.playable,to_mask):
            if self.piece_type_at(move.to_square)!=chess.KING and not self.is_castling(move):yield move
        direction=1 if self.turn else -1
        last=self.rows-1 if self.turn else 0
        for sq in chess.scan_forward(self.pawns & self.occupied_co[self.turn] & from_mask & self.playable):
            f,r=chess.square_file(sq),chess.square_rank(sq);nr=r+direction
            if not 0<=nr<self.rows:continue
            for df in (0,-1,1):
                nf=f+df
                if not 0<=nf<self.columns:continue
                to=chess.square(nf,nr)
                if not chess.BB_SQUARES[to] & to_mask:continue
                piece=self.piece_at(to)
                if (df==0 and piece is not None) or (df!=0 and (piece is None or piece.color==self.turn or piece.piece_type==chess.KING)):continue
                for promotion in ((chess.QUEEN,chess.ROOK,chess.BISHOP,chess.KNIGHT) if nr==last else (None,)):
                    yield chess.Move(sq,to,promotion=promotion)

def compact_fen(board,columns,rows):
    lines=[]
    for r in reversed(range(rows)):
        line='';empty=0
        for f in range(columns):
            p=board.piece_at(chess.square(f,r))
            if p is None:empty+=1
            else:
                if empty:line+=str(empty);empty=0
                line+=p.symbol()
        if empty:line+=str(empty)
        lines.append(line)
    return '/'.join(lines)+f" {'w' if board.turn else 'b'} - - {board.halfmove_clock} {board.fullmove_number}"

class RectEngine(Engine):
    def __init__(self):
        self.process=subprocess.Popen([str(ENGINE),'load',str(CONFIG)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
        self.send('uci');self.until('uciok')
        for command in ('setoption name Threads value 1','setoption name Hash value 32','setoption name Use NNUE value false'):self.send(command)
        self.size=None
    def close(self):
        try:super().close()
        finally:
            self.process.stdin.close();self.process.stdout.close()
    def position(self,fen,size):
        columns,rows=dimensions(*size)
        if self.size!=size:
            self.send(f'setoption name UCI_Variant value cloud{columns}x{rows}')
            self.send('setoption name Threads value 1');self.size=size
        self.send('ucinewgame');self.send('setoption name Clear Hash');self.send('isready');self.until('readyok')
        self.send('position fen '+compact_fen(RectBoard(fen,columns,rows),columns,rows))
