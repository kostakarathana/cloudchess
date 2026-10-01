"""Build the five isolated Git experiments and compare exact evidence and timings.
Run without --build to reuse binaries. Engine libraries/bridge objects must already
exist (see scripts/build_performance_probe.py). Results stay in ignored reports/.
"""
import argparse
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/perf-v19'
VARIANTS = {
    'baseline': 'fc8a1dc',
    'tag-metrics': 'perf/v19-tag-metrics',
    'forest-anchors': 'perf/v19-forest-anchors',
    'digest-format': 'perf/v19-digest-format',
    'certified-descriptors': 'perf/v19-certified-descriptors',
    'binary-snapshots': 'perf/v19-binary-snapshots',
    'combined': None,
}
SOURCES = ['NativeProfiles', 'PuzzleCoach', 'ModeDifficulty', 'ChallengeModes',
           'CollectionCatalog', 'BoardGeometry']

def build(name, revision):
    # Extract tracked Swift files without changing any working checkout.
    with tempfile.TemporaryDirectory(prefix='cloudchess-sweep-') as directory:
        sources = []
        for stem in SOURCES:
            source = f'CloudChess/{stem}.swift'
            path = Path(directory) / f'{stem}.swift'
            data = subprocess.check_output(['git', 'show', f'{revision}:{source}'], cwd=ROOT) if revision else (ROOT / source).read_bytes()
            path.write_bytes(data)
            sources.append(str(path))
        objects = [f'reports/analysis-v12/build/{s}.o' for s in ['bridge', 'dotprod', 'puzzle']]
        subprocess.run(['swiftc', '-O', '-D', 'DEBUG', '-parse-as-library',
                        '-import-objc-header', 'NativeEngine/CloudChess-Bridging-Header.h',
                        *sources, 'scripts/benchmark_sweep.swift', *objects,
                        'NativeEngine/lib/macosx/libStockfish.a',
                        'NativeEngine/lib/macosx/libStockfishDotprod.a',
                        '-lc++', '-lsqlite3', '-o', str(OUT / name)], cwd=ROOT, check=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.build:
        for name, revision in VARIANTS.items():
            build(name, revision)
    env = dict(os.environ,
               CC_MODE_MODEL_PATH=str(ROOT / 'CloudChess/EngineResources/mode-difficulty-v3.json'),
               CC_CERTIFIED_STARTS_PATH=str(ROOT / 'CloudChess/EngineResources/certified-challenge-starts.json'))
    for trial in range(3):
        order = list(VARIANTS)
        random.Random(910 + trial).shuffle(order)
        for name in order:
            result = json.loads(subprocess.check_output([str(OUT / name)], cwd=ROOT, env=env))
            (OUT / f'{name}-{trial}.json').write_text(json.dumps(result, indent=2))
            print(name, trial, result['timings'], flush=True)
    summary = {}
    for name in VARIANTS:
        rows = [json.loads((OUT / f'{name}-{i}.json').read_text()) for i in range(3)]
        assert len({r['evidence'] for r in rows}) == 1
        summary[name] = {'medians': {key: statistics.median(row['timings'][key] for row in rows)
                                    for key in rows[0]['timings']}, 'evidence': rows[0]['evidence']}
    assert len({v['evidence'] for v in summary.values()}) == 1, 'Selection/evidence drift detected'
    (OUT / 'comparison.json').write_text(json.dumps(summary, indent=2))
    print('ALL EXACT EVIDENCE MATCHES', flush=True)

if __name__ == '__main__':
    main()
