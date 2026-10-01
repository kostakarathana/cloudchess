import unittest,sys,random
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import engine_bridge as bridge
import chess
class EngineBridgeTests(unittest.TestCase):
    def test_initial_board(self):
        state=bridge.execute('state',{'moves':[]});self.assertEqual(len(state['legal']),20);self.assertEqual(state['turn'],'white')
    def test_illegal_move_rejected(self):
        with self.assertRaises(ValueError):bridge.execute('move',{'moves':[],'move':'e2e5'})
    def test_illegal_history_rejected(self):
        with self.assertRaises(ValueError):bridge.execute('state',{'moves':['a1a8']})
    def test_turn_guard(self):
        with self.assertRaises(ValueError):bridge.execute('reply',{'moves':[]})
        with self.assertRaises(ValueError):bridge.execute('move',{'moves':['e2e4'],'move':'e7e5'})
    def test_stockfish_reply_is_legal(self):
        state=bridge.execute('reply',{'moves':['e2e4']});self.assertEqual(len(state['moves']),2);self.assertEqual(state['turn'],'white');self.assertTrue(chess.Board(state['fen']).is_valid())
    def test_hint_keeps_board_unchanged(self):
        state=bridge.execute('hint',{'moves':[]});self.assertEqual(state['moves'],[]);self.assertIn(state['lastMove'],state['legal'])
    def test_castling(self):
        moves=['e2e4','e7e5','g1f3','b8c6','f1c4','g8f6','e1g1'];state=bridge.execute('state',{'moves':moves});b=chess.Board(state['fen']);self.assertEqual(b.piece_at(chess.G1).symbol(),'K');self.assertEqual(b.piece_at(chess.F1).symbol(),'R');self.assertEqual(state['san'][-1],'O-O')
    def test_en_passant_capture(self):
        moves=['e2e4','a7a6','e4e5','d7d5','e5d6'];state=bridge.execute('state',{'moves':moves});self.assertEqual(state['capturedWhite'],['P']);self.assertIsNone(chess.Board(state['fen']).piece_at(chess.D5))
    def test_game_over(self):
        moves=['f2f3','e7e5','g2g4','d8h4'];state=bridge.execute('state',{'moves':moves});self.assertEqual(state['legal'],[]);self.assertEqual(state['result'],'Cloud wins this one.')
    def test_repetition_preserved(self):
        moves=['g1f3','g8f6','f3g1','f6g8']*2;self.assertIn('Draw',bridge.execute('state',{'moves':moves})['result'])
    def test_replay_and_notation_across_1000_legal_plies(self):
        rng=random.Random(73);board=chess.Board();count=0
        while count<1000:
            if board.is_game_over(claim_draw=True):board=chess.Board()
            move=rng.choice(list(board.legal_moves));board.push(move)
            actual=bridge.execute('state',{'moves':[m.uci() for m in board.move_stack]});self.assertEqual(actual['fen'],board.fen());self.assertEqual(set(actual['legal']),{m.uci() for m in board.legal_moves});count+=1
if __name__=='__main__':unittest.main(verbosity=2)
