import sys,random,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import engine_bridge as bridge
from rectangular_chess import initial_board,RectBoard,RectEngine
import chess

class RectangularTests(unittest.TestCase):
    def test_all_dimensions_and_2400_independent_engine_positions(self):
        randomizer=random.Random(4826);positions=0
        with RectEngine() as engine:
            for columns in range(4,9):
                for rows in range(4,9):
                    if (columns,rows)==(8,8):continue
                    board=initial_board(columns,rows)
                    for _ in range(100):
                        if board.is_game_over(claim_draw=True):board=initial_board(columns,rows)
                        self.assertTrue(board.is_valid(),(columns,rows,board.fen()))
                        actual={m.uci() for m in board.legal_moves}
                        expected=set(engine.legal(board.fen(),(columns,rows)))
                        self.assertEqual(actual,expected,(columns,rows,board.fen()))
                        for move in board.legal_moves:
                            self.assertLess(chess.square_file(move.to_square),columns)
                            self.assertLess(chess.square_rank(move.to_square),rows)
                        move=chess.Move.from_uci(randomizer.choice(sorted(actual)))
                        board.push(move);positions+=1
                    state=bridge.execute('state',{'columns':columns,'rows':rows,'moves':[m.uci() for m in board.move_stack]})
                    self.assertEqual(state['fen'],board.fen());self.assertEqual(state['columns'],columns);self.assertEqual(state['rows'],rows)
                    print(f'{columns}x{rows}: 100 engine comparisons passed',flush=True)
        self.assertEqual(positions,2400)
    def test_edge_promotions_and_forbidden_moves(self):
        with RectEngine() as engine:
            for c in range(4,9):
                for r in range(4,9):
                    if (c,r)==(8,8):continue
                    for color in (chess.WHITE,chess.BLACK):
                        b=RectBoard(None,c,r);b.turn=color
                        b.set_piece_at(chess.square(0 if color else c-1,0),chess.Piece(chess.KING,chess.WHITE))
                        b.set_piece_at(chess.square(c-1 if color else 0,r-1),chess.Piece(chess.KING,chess.BLACK))
                        rank=r-2 if color else 1
                        b.set_piece_at(chess.square(1,rank),chess.Piece(chess.PAWN,color))
                        self.assertTrue(b.is_valid())
                        legal=list(b.legal_moves)
                        self.assertEqual(len([m for m in legal if m.promotion]),4)
                        self.assertEqual({m.uci() for m in legal},set(engine.legal(b.fen(),(c,r))))
                    b=initial_board(c,r)
                    self.assertFalse(any(b.is_castling(m) for m in b.legal_moves))
                    self.assertNotIn('a2a4',{m.uci() for m in b.legal_moves})
    def test_request_validation(self):
        for c,r in [(3,6),(4,9),(0,0),(True,5),('5',5),(None,8)]:
            with self.assertRaises(ValueError):bridge.execute('state',{'columns':c,'rows':r})
        with self.assertRaises(ValueError):bridge.execute('move',{'columns':4,'rows':6,'move':'d2e3'})
    def test_engine_reply_hint_and_undo_state(self):
        for c,r in [(5,5),(6,6),(7,7),(4,6),(6,4),(4,8),(8,4)]:
            args={'columns':c,'rows':r}
            initial=bridge.execute('state',args)
            hint=bridge.execute('hint',args);self.assertIn(hint['lastMove'],initial['legal']);self.assertEqual(hint['fen'],initial['fen'])
            first=bridge.execute('move',dict(args,move='b1a3'))
            reply=bridge.execute('reply',dict(args,moves=first['moves']))
            self.assertEqual(reply['turn'],'white');self.assertEqual(len(reply['moves']),2)
            self.assertEqual(bridge.execute('state',dict(args,moves=[]))['fen'],initial['fen'])
if __name__=='__main__':unittest.main(verbosity=2)
