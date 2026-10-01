import subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
name=sys.argv[1];destination=sys.argv[2]
sources=[f'CloudChess/{s}.swift' for s in ['NativeProfiles','PuzzleCoach','ModeDifficulty','ChallengeModes','CollectionCatalog','BoardGeometry']]
objects=[f'reports/analysis-v12/build/{s}.o' for s in ['bridge','dotprod','puzzle']]
subprocess.run(['swiftc','-O','-D','DEBUG','-parse-as-library','-import-objc-header','NativeEngine/CloudChess-Bridging-Header.h',*sources,f'scripts/{name}.swift',*objects,'NativeEngine/lib/macosx/libStockfish.a','NativeEngine/lib/macosx/libStockfishDotprod.a','-lc++','-lsqlite3','-o',destination],cwd=ROOT,check=True)
