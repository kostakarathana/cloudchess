#!/usr/bin/env python3
"""Play-on hearts, the adaptive defender, never-repeat retirement, ad allowance and on-track proof regressions.
Requires the macOS native libraries (scripts/build_native_engine.py --sdk macosx);
the candidate-proof checks also need python-chess.
"""
from pathlib import Path
import os,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/play-on';OUT.mkdir(parents=True,exist_ok=True)
def run(command,**kwargs):
    return subprocess.run(command,cwd=ROOT,check=True,**kwargs)
flags=['xcrun','clang++','-std=c++17','-O3','-fobjc-arc','-DIS_64BIT','-DUSE_NEON=8','-DUSE_POPCNT','-DNNUE_EMBEDDING_OFF']
for source,name,extra in [('ChessBridge','bridge',['-DCC_DUAL_ENGINE']),('ChessBridgeDotprod','dotprod',['-DNDEBUG','-march=armv8.2-a+dotprod','-DUSE_NEON_DOTPROD']),('PuzzleBridge','puzzle',['-DNDEBUG'])]:
    run([*flags,*extra,'-c',f'NativeEngine/{source}.mm','-o',str(OUT/(name+'.o'))])
link=[*[str(OUT/(name+'.o')) for name in ['bridge','dotprod','puzzle']],'NativeEngine/lib/macosx/libStockfish.a','NativeEngine/lib/macosx/libStockfishDotprod.a','-lc++','-lsqlite3']
sources=[f'CloudChess/{s}.swift' for s in ['NativeProfiles','PuzzleCoach','ModeDifficulty','ChallengeModes','CollectionCatalog','BoardGeometry']]
bank='CloudChess/EngineResources/puzzles.json'
for test in ['test_failure_retirement','test_focused_puzzles','test_prepared_gate','test_puzzle_shuffle','test_skill_tracking']:
    run(['swiftc','-O','-D','DEBUG','-parse-as-library','-import-objc-header','NativeEngine/CloudChess-Bridging-Header.h',*sources,f'scripts/{test}.swift',*link,'-o',str(OUT/test)])
    with (OUT/(test+'.log')).open('w') as log:run([str(OUT/test),bank],stdout=log)
    print(test,(OUT/(test+'.log')).read_text().strip()[-300:])
run(['swiftc','-O','-parse-as-library','CloudChess/PuzzleAllowance.swift','scripts/test_ad_allowance.swift','-o',str(OUT/'test_ad_allowance')])
print(run([str(OUT/'test_ad_allowance')],capture_output=True,text=True).stdout.strip())
# The tiny command-line transport calls the exact shipping CCPuzzle entrypoint.
cli=OUT/'proof_cli.mm'
cli.write_text('''#import "ChessBridge.h"
#include <iostream>
uint64_t CCBackgroundEpoch(void){return 0;}
int main(){std::string line;while(std::getline(std::cin,line)){@autoreleasepool {
NSData *data=[[NSString stringWithUTF8String:line.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
NSDictionary *result=CCPuzzle([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
NSData *output=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
std::cout<<std::string((const char*)output.bytes,output.length)<<std::endl;
}}}
''')
run(['xcrun','clang++','-std=c++17','-O3','-fobjc-arc','-framework','Foundation','-I','NativeEngine',str(cli),str(OUT/'puzzle.o'),'-o',str(OUT/'proof')])
env=dict(os.environ,CC_PUZZLE_BINARY=str(OUT/'proof'))
for test in ['test_play_on_puzzles','test_adaptive_defense','test_candidate_proofs','test_puzzle_engine']:
    with (OUT/(test+'.log')).open('w') as log:
        result=subprocess.run([sys.executable,str(ROOT/'scripts'/(test+'.py'))],cwd=ROOT.parent,env=env,stdout=log,stderr=subprocess.STDOUT)
    print(test,'exit',result.returncode,(OUT/(test+'.log')).read_text().strip()[-400:])
