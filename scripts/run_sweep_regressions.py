"""Compare the optimized forest to the actual pre-optimization implementation."""
from pathlib import Path
import os,subprocess,tempfile
R=Path(__file__).resolve().parents[1];O=R/'reports/perf-v19';O.mkdir(parents=True,exist_ok=True)
def run(cmd,**kw):return subprocess.run(cmd,cwd=R,check=True,**kw)
with tempfile.TemporaryDirectory(prefix='cloudchess-reference-') as directory:
 p=Path(directory);source=run(['git','show','ac2572e:CloudChess/ModeDifficulty.swift'],capture_output=True,text=True).stdout
 source=source.split('/// Revalidation at handoff')[0].replace('enum ModeDifficulty','enum ReferenceModeDifficulty')
 (p/'Reference.swift').write_text(source)
 sources=[f'CloudChess/{s}.swift' for s in ['NativeProfiles','PuzzleCoach','ModeDifficulty','ChallengeModes','CollectionCatalog','BoardGeometry']]
 objects=[f'reports/analysis-v12/build/{s}.o' for s in ['bridge','dotprod','puzzle']]
 run(['swiftc','-O','-D','DEBUG','-parse-as-library','-import-objc-header','NativeEngine/CloudChess-Bridging-Header.h',*sources,str(p/'Reference.swift'),'scripts/test_sweep_equivalence.swift',*objects,'NativeEngine/lib/macosx/libStockfish.a','NativeEngine/lib/macosx/libStockfishDotprod.a','-lc++','-lsqlite3','-o',str(p/'tests')])
 env=dict(os.environ,CC_MODE_MODEL_PATH=str(R/'CloudChess/EngineResources/mode-difficulty-v3.json'),CC_CERTIFIED_STARTS_PATH=str(R/'CloudChess/EngineResources/certified-challenge-starts.json'))
 with (O/'equivalence.json').open('w') as log:run([str(p/'tests')],env=env,stdout=log)
print((O/'equivalence.json').read_text())
