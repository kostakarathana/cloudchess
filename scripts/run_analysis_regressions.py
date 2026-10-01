#!/usr/bin/env python3
"""Reproduce engine equivalence, full-budget latency and search handoff tests.

The baseline and fast kernels execute sequentially, never concurrently. Timings
are host CPU measurements; simulator gameplay is covered by CloudChessUITests.
"""
import json
import os
from pathlib import Path
import statistics
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/analysis-v12'
BUILD=OUT/'build'

def run(command,**kwargs):
    return subprocess.run(command,cwd=ROOT,check=True,**kwargs)

def main():
    BUILD.mkdir(parents=True,exist_ok=True)
    run(['python3','scripts/build_native_engine.py','--sdk','macosx'])
    flags=['xcrun','clang++','-std=c++17','-O3','-fobjc-arc','-DIS_64BIT','-DUSE_NEON=8','-DUSE_POPCNT','-DNNUE_EMBEDDING_OFF']
    for source,name,extra in [
        ('ChessBridge','bridge',['-DCC_DUAL_ENGINE','-DCC_ENGINE_TESTING']),
        ('ChessBridgeDotprod','dotprod',['-DNDEBUG','-march=armv8.2-a+dotprod','-DUSE_NEON_DOTPROD']),
        ('PuzzleBridge','puzzle',['-DNDEBUG']),
    ]:
        run([*flags,*extra,'-c',f'NativeEngine/{source}.mm','-o',str(BUILD/(name+'.o'))])
    link=[*[str(BUILD/(name+'.o')) for name in ['bridge','dotprod','puzzle']],
          'NativeEngine/lib/macosx/libStockfish.a','NativeEngine/lib/macosx/libStockfishDotprod.a','-lc++','-lsqlite3']
    sources=[f'CloudChess/{s}.swift' for s in ['NativeProfiles','PuzzleCoach','ModeDifficulty','ChallengeModes','CollectionCatalog','BoardGeometry']]
    for name,script,extra in [('benchmark','benchmark_open_turns',[]),('kernels','test_engine_kernels',[]),('search','test_search_handoff',sources)]:
        run(['swiftc','-O','-D','DEBUG','-parse-as-library','-import-objc-header','NativeEngine/CloudChess-Bridging-Header.h',*extra,f'scripts/{script}.swift',*link,'-o',str(BUILD/name)])
    env=dict(os.environ,CC_NETWORK_PATH=str(ROOT/'CloudChess/EngineResources/nn-1a298aa575a0.nnue'))
    env.pop('CC_FORCE_BASELINE_ENGINE',None)
    for name in ['benchmark','kernels','search']:
        for kernel in ['baseline','optimized']:
            mode=dict(env)
            if kernel=='baseline':mode['CC_FORCE_BASELINE_ENGINE']='1'
            with (OUT/f'{name}-{kernel}.json').open('w') as log:
                run([str(BUILD/name)],env=mode,stdout=log)
    b=json.loads((OUT/'benchmark-baseline.json').read_text())
    a=json.loads((OUT/'benchmark-optimized.json').read_text())
    assert b['kernel']=='neon' and a['kernel']=='neon-dotprod'
    keys=['cp','nodes','depth','pv','history','root']
    for old,new in zip(b['measurements'],a['measurements']):
        assert all(old[k]==new[k] for k in keys)
    old=statistics.mean(r['seconds'] for r in b['measurements'])
    new=statistics.mean(r['seconds'] for r in a['measurements'])
    kb=json.loads((OUT/'kernels-baseline.json').read_text())
    ka=json.loads((OUT/'kernels-optimized.json').read_text())
    assert len(kb['positions'])==len(ka['positions'])
    for baseline,fast in zip(kb['positions'],ka['positions']):
        assert baseline['fen']==fast['fen'] and baseline['evaluations']==fast['evaluations']
    summary=dict(status='passed',scope=b['scope'],coldFullBudgetSearches=len(a['measurements']),
                 baselineMeanSeconds=old,optimizedMeanSeconds=new,reductionPercent=(1-new/old)*100,
                 identicalFullBudgetEvidence=keys,bankPositions=len(kb['positions']),
                 checks=kb['checks']+ka['checks']+sum(json.loads((OUT/f'search-{k}.json').read_text())['checks'] for k in ['baseline','optimized']))
    (OUT/'comparison.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))

if __name__=='__main__':main()
