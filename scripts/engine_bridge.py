#!/usr/bin/env python3
"""Local simulator transport for Chess Lab's unhandicapped Stockfish 19 engine.
State is reconstructed from legal move history per request; no user DB is changed.
"""
import sys,json,argparse,threading
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'chess-lab'))
import chess
from chesslab.strong_engine import StrongEngine
from rectangular_chess import initial_board,dimensions,RectEngine
ENGINE_LOCK=threading.Lock()

def board_from(moves,columns=8,rows=8):
    if not isinstance(moves,list) or len(moves)>2000:raise ValueError('Invalid move history')
    board=initial_board(columns,rows)
    for uci in moves:
        if not isinstance(uci,str):raise ValueError('Invalid move')
        move=chess.Move.from_uci(uci)
        if move not in board.legal_moves:raise ValueError('Illegal move in history')
        board.push(move)
    return board

def describe(board,hint=None,columns=8,rows=8):
    replay=initial_board(columns,rows);san=[];captures={'white':[],'black':[]}
    for move in board.move_stack:
        if replay.is_capture(move):
            piece=replay.piece_at(move.to_square)
            captures['white' if replay.turn else 'black'].append(piece.symbol().upper() if piece else 'P')
        san.append(replay.san(move));replay.push(move)
    outcome=board.outcome(claim_draw=True)
    result=None
    if outcome:
        result='Draw · '+outcome.termination.name.replace('_',' ').lower() if outcome.winner is None else ('You win. Beautifully played.' if outcome.winner else 'Cloud wins this one.')
    return dict(columns=columns,rows=rows,fen=board.fen(),moves=[m.uci() for m in board.move_stack],san=san,legal=[m.uci() for m in board.legal_moves],turn='white' if board.turn else 'black',check=board.is_check(),result=result,capturedWhite=captures['white'],capturedBlack=captures['black'],lastMove=hint or (board.peek().uci() if board.move_stack else None))

def execute(route,data):
    if not isinstance(data,dict):raise ValueError('Expected an object')
    columns,rows=dimensions(data.get('columns',8),data.get('rows',8))
    board=board_from(data.get('moves',[]),columns,rows)
    def state(hint=None):return describe(board,hint,columns,rows)
    if route=='state':return state()
    if board.is_game_over(claim_draw=True):raise ValueError('This game has finished')
    if route=='move':
        if board.turn!=chess.WHITE:raise ValueError('Wait for the engine reply')
        move=chess.Move.from_uci(data.get('move',''))
        if move not in board.legal_moves:raise ValueError('Choose a legal move')
        board.push(move);return state()
    if route in ('reply','hint'):
        if route=='reply' and board.turn!=chess.BLACK:raise ValueError('It is your turn')
        with ENGINE_LOCK:
            if (columns,rows)==(8,8):
                with StrongEngine() as engine:pv=engine.analyse(board.fen(),8,nodes=2000000,depth=40)[0]['pv']
            else:
                with RectEngine() as engine:pv=engine.analyse(board.fen(),(columns,rows),nodes=250000,depth=24,multipv=1)[0]['pv']
        move=chess.Move.from_uci(pv[0])
        if move not in board.legal_moves:raise RuntimeError('Engine returned an illegal move')
        if route=='hint':return state(hint=move.uci())
        board.push(move);return state()
    raise ValueError('Unknown route')

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_json(200,{'ok':True,'engine':StrongEngine.metadata}) if self.path=='/health' else self.send_json(404,{'error':'Not found'})
    def do_POST(self):
        try:
            length=int(self.headers.get('Content-Length','0'))
            if length>100000:raise ValueError('Request too large')
            data=json.loads(self.rfile.read(length))
            self.send_json(200,execute(self.path.strip('/'),data))
        except (ValueError,TypeError,KeyError) as e:self.send_json(400,{'error':str(e)})
        except Exception as e:self.log_error('%s',e);self.send_json(500,{'error':'Engine is unavailable. Please reconnect.'})
    def send_json(self,code,value):
        payload=json.dumps(value).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8767);parser.add_argument('--host',default='127.0.0.1');args=parser.parse_args()
    print('CloudChess engine bridge on http://%s:%d'%(args.host,args.port),flush=True)
    ThreadingHTTPServer((args.host,args.port),Handler).serve_forever()
