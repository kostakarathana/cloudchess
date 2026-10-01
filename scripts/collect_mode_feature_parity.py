import json
import train_mode_difficulty as m
m.BIN='/tmp/cloudchess-native-adaptive'
e=m.Engine();out=[]
try:
 for kind in m.KINDS:
  for q in [q for q in m.jobs() if q['kind']==kind][:6]:
   r=e.analyse(q['fen'],multipv=3)
   opponent=1300 if kind in ['finish','tenMoves'] else 0
   x=m.features(q,r,r['evaluations'],opponent)
   out.append(dict(fen=q['fen'],kind=kind,turns=q['turns'],opponent=opponent,response=r,features=x))
 (m.OUT/'mode-v3-feature-parity.json').write_text(json.dumps(out));print('feature probes',len(out),flush=True)
finally:e.close()
