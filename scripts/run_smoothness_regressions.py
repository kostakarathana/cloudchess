#!/usr/bin/env python3
"""Portable persistence/engine regressions; uses real full-budget bundled Stockfish.
Run from any directory. Simulator UI tests remain in CloudChessUITests.
"""
import json, os, statistics, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/smooth-v11'
SOURCES = ['NativeProfiles', 'PuzzleCoach', 'ModeDifficulty', 'ChallengeModes', 'CollectionCatalog', 'BoardGeometry']

def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    run(['python3', 'scripts/build_native_engine.py', '--sdk', 'macosx'])
    with tempfile.TemporaryDirectory(prefix='cloudchess-smoothness-') as temporary:
        folder = Path(temporary)
        for name in ['ChessBridge', 'PuzzleBridge']:
            run(['xcrun', 'clang++', '-std=c++17', '-O3', '-fobjc-arc', '-DNDEBUG', '-DIS_64BIT', '-DUSE_NEON=8', '-DUSE_POPCNT', '-DNNUE_EMBEDDING_OFF', '-c', f'NativeEngine/{name}.mm', '-o', str(folder / (name + '.o'))])
        env = dict(os.environ, CC_NETWORK_PATH=str(ROOT / 'CloudChess/EngineResources/nn-1a298aa575a0.nnue'))
        for name, script, variants in [
            ('persistence', 'test_coach_persistence', [('persistence', [])]),
            ('search', 'test_search_handoff', [('search', [])]),
            ('landing', 'benchmark_landing_overlap', [('landing-before', ['--serial']), ('landing-after', [])]),
        ]:
            binary = folder / name
            with (OUT / (name + '-build.log')).open('w') as log:
                run(['swiftc', '-O', '-D', 'DEBUG', '-import-objc-header', 'NativeEngine/CloudChess-Bridging-Header.h', *[f'CloudChess/{s}.swift' for s in SOURCES], f'scripts/{script}.swift', str(folder / 'ChessBridge.o'), str(folder / 'PuzzleBridge.o'), 'NativeEngine/lib/macosx/libStockfish.a', '-lc++', '-lsqlite3', '-o', str(binary)], stdout=log, stderr=subprocess.STDOUT)
            for report, arguments in variants:
                with (OUT / (report + '.json')).open('w') as log:
                    run([str(binary), *arguments], env=env, stdout=log)
        before = json.loads((OUT / 'landing-before.json').read_text())
        after = json.loads((OUT / 'landing-after.json').read_text())
        evidence = ['cp', 'nodes', 'pv', 'history', 'root']
        for old, new in zip(before['measurements'], after['measurements']):
            assert all(old[key] == new[key] for key in evidence)
        old = statistics.mean(m['placementToVerdictSeconds'] for m in before['measurements'])
        new = statistics.mean(m['placementToVerdictSeconds'] for m in after['measurements'])
        (OUT / 'comparison.json').write_text(json.dumps(dict(beforeMeanSeconds=old, afterMeanSeconds=new, reductionPercent=(1-new/old)*100, identicalEvidence=evidence, scope=before['scope']), indent=2))
        print(f'Passed. Benchmark and regression receipts: {OUT}')

if __name__ == '__main__':
    main()
