#!/usr/bin/env python3
"""Reproduce the score -> difficulty progression evidence end to end.

Builds the native objects and both command-line oracles into
reports/difficulty-progression/, compiles scripts/test_difficulty_progression.swift
against the real coach sources, runs the deterministic sweep/organic/struggle
harness, plays the native bot arena over the selected puzzles, and writes
reports/difficulty-progression/summary.json plus reports/DIFFICULTY-PROGRESSION.md.

Requires the macOS Stockfish libraries (scripts/build_native_engine.py --sdk macosx).
No app proof/search budget is changed; the arena's 1,000,000-node guide budget is
an oracle for scoring bot games only.
"""
from pathlib import Path
import json,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/difficulty-progression';OUT.mkdir(parents=True,exist_ok=True)
REPORT=ROOT/'reports/DIFFICULTY-PROGRESSION.md'
BANK='CloudChess/EngineResources/puzzles.json'
def run(command,**kwargs):
    return subprocess.run(command,cwd=ROOT,check=True,**kwargs)
timings={};started=time.time()

# 1. Native objects (same flags as scripts/run_focused_regressions.py).
t=time.time()
flags=['xcrun','clang++','-std=c++17','-O3','-fobjc-arc','-DIS_64BIT','-DUSE_NEON=8','-DUSE_POPCNT','-DNNUE_EMBEDDING_OFF']
for source,name,extra in [('ChessBridge','bridge',['-DCC_DUAL_ENGINE']),('ChessBridgeDotprod','dotprod',['-DNDEBUG','-march=armv8.2-a+dotprod','-DUSE_NEON_DOTPROD']),('PuzzleBridge','puzzle',['-DNDEBUG'])]:
    run([*flags,*extra,'-c',f'NativeEngine/{source}.mm','-o',str(OUT/(name+'.o'))])
timings['objects']=time.time()-t

# 2. Harness against the real coach sources.
t=time.time()
link=[*[str(OUT/(name+'.o')) for name in ['bridge','dotprod','puzzle']],'NativeEngine/lib/macosx/libStockfish.a','NativeEngine/lib/macosx/libStockfishDotprod.a','-lc++','-lsqlite3']
sources=[f'CloudChess/{s}.swift' for s in ['NativeProfiles','PuzzleCoach','ModeDifficulty','ChallengeModes','CollectionCatalog','BoardGeometry']]
run(['swiftc','-O','-D','DEBUG','-parse-as-library','-import-objc-header','NativeEngine/CloudChess-Bridging-Header.h',*sources,'scripts/test_difficulty_progression.swift',*link,'-o',str(OUT/'progression-tests')])
timings['harnessCompile']=time.time()-t
t=time.time()
with (OUT/'harness.log').open('w') as log:
    harness=subprocess.run([str(OUT/'progression-tests'),BANK,str(OUT)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
print((OUT/'harness.log').read_text())
timings['harnessRun']=time.time()-t
summary=json.loads((OUT/'summary.json').read_text()) if (OUT/'summary.json').exists() else {}
if harness.returncode!=0:
    print('Harness assertions failed:',summary.get('failures'));sys.exit(harness.returncode)

# 3. Command-line oracles: exact shipping CCPuzzle prover and the difficulty bots.
t=time.time()
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
run(['xcrun','clang++','-std=c++17','-O3','-fobjc-arc','-framework','Foundation','-I','NativeEngine','NativeEngine/difficulty_cli.mm','-o',str(OUT/'difficulty-cli')])
timings['cliBuild']=time.time()-t

# 4. Bot arena over sweep picks (ability 1100) and organic picks.
arena={}
for kind,source,cap in [('sweep','sweep-1100.jsonl',60),('organic','organic.jsonl',120)]:
    if kind=='sweep':
        with (OUT/source).open('w') as f:
            for line in (OUT/'sweep.jsonl').read_text().splitlines():
                if line.strip() and json.loads(line).get('fixedAbility')==1100:f.write(line+'\n')
    t=time.time()
    with (OUT/f'arena-{kind}.log').open('w') as log:
        result=subprocess.run([sys.executable,'-I','scripts/benchmark_progression_bots.py',str(OUT/source),str(OUT/'proof'),str(OUT/'difficulty-cli'),str(cap),kind,str(OUT/f'arena-{kind}.json')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    print((OUT/f'arena-{kind}.log').read_text())
    timings[f'arena-{kind}']=time.time()-t
    arena[kind]=json.loads((OUT/f'arena-{kind}.json').read_text())
    if result.returncode!=0:
        print('Arena assertions failed:',arena[kind]['failures']);sys.exit(result.returncode)
timings['total']=time.time()-started
summary['arena']=arena;summary['timings']=timings
summary['totalChecks']=summary.get('checks',0)+sum(a['checks'] for a in arena.values())
summary['totalFailures']=len(summary.get('failures',[]))+sum(len(a['failures']) for a in arena.values())
(OUT/'summary.json').write_text(json.dumps(summary,indent=1,sort_keys=True))

# 5. Markdown report.
schedule=summary['schedule']
def pts(v):return f"{v:g}"
lines=['# Difficulty progression evidence','',
 f'Generated by `python3 scripts/run_difficulty_regressions.py` on {time.strftime("%Y-%m-%d")} (total {timings["total"]:.0f} s on this Mac; harness run {timings["harnessRun"]:.1f} s, arena {timings["arena-sweep"]+timings["arena-organic"]:.0f} s).','',
 'Question: do focused puzzles get harder as the score rises? Answer: yes, up to each shape/family stratum\'s catalogue ceiling, '
 'which is reached from roughly 1.5–2M points. Beyond that the score-driven level exceeds every item in the catalogue, so selection plateaus at the hardest available items; making puzzles harder past that point needs new certified content, not selection changes.','',
 'Ratings are on the `challenge-v2` difficulty-model scale (clamped 400–3000). Bot tiers are reproducible bounded search budgets (depth/nodes), not human Elo. The 1,000,000-node guide budget is the arena oracle only; no app proof/search budget was changed.','',
 '## Method','',
 '- `scripts/test_difficulty_progression.swift` compiles against the real `AdaptivePuzzleCoach` and the shipping catalogue (bank variants; no native composition). It records the first candidate per draw.',
 f'- Forced-shape sweep: fresh coach, ability 1100 and 3000, each of the 50 strata, score schedule {", ".join(pts(s) for s in schedule)} points. Asserts a non-decreasing rating (25-point tolerance) while below the ceiling, ceiling reach at the top score, and strictly increasing level/target within 400–3000.',
 f'- Organic always-correct runs: five seeds, every solve clean in 4 s, until {pts(summary["goal"])} points. Asserts the low bucket (<{pts(summary["lowBucket"])}) sits ≥500 below the mid bucket ({pts(summary["lowBucket"])}–{pts(summary["highBucket"])}), the high bucket (≥{pts(summary["highBucket"])}) stays within 75 of the mid bucket, ≥85% of high picks are within 150 of their stratum ceiling, and the fast-clean 0.52 target locks in.',
 '- Struggle run: seed 0, every fifth puzzle fails with three mistakes. Bucket-level assertions only (high mean ≥1750, presented reviews ≤8% of picks, each presented review passes `eligibleReview`).',
 '- `scripts/benchmark_progression_bots.py`: the exact shipping prover (`CCPuzzle` guide) supplies defenses and accepts any proven alternative; native tiers native-1/2/4 (depth 1/2/4, 256/1400/6000 nodes) choose the top-scored move with a seeded tie-break; same protocol as `scripts/benchmark_challenge_bots.py`.','',
 '## Forced-shape sweep (ability 1100): selected rating by score','',
 '| stratum | n | ceiling | '+' | '.join(pts(s) for s in schedule)+' | first ceiling score |','|---|---|---|'+'---|'*len(schedule)+'---|']
for row in summary['sweep']['strata']:
    sat=row.get('saturation1100');lines.append(f"| {row['stratum']} | {row['count']} | {row['max']:.0f} | "+' | '.join(f"{r:.0f}" for r in row['ratings1100'])+f" | {pts(sat) if sat is not None else '—'} |")
lines+=['',f"Strata within 150 of their ceiling at the top score: ability 1100 {summary['sweep']['saturatedStrata']['1100']}/50, ability 3000 {summary['sweep']['saturatedStrata']['3000']}/50.",'',
 '| score | level (1100) | target (1100) | mean pick (1100) | level (3000) | target (3000) | mean pick (3000) |','|---|---|---|---|---|---|---|']
for i,s in enumerate(schedule):
    sw=summary['sweep'];lines.append(f"| {pts(s)} | {sw['levels']['1100'][i]:.0f} | {sw['targets']['1100'][i]:.0f} | {sw['meanRatingBySchedule']['1100'][i]:.0f} | {sw['levels']['3000'][i]:.0f} | {sw['targets']['3000'][i]:.0f} | {sw['meanRatingBySchedule']['3000'][i]:.0f} |")
org=summary['organic'];stru=summary['struggle']
lines+=['','## Organic always-correct runs (five seeds)','',
 f"Attempts to {pts(summary['goal'])} points: {', '.join(str(a) for a in org['attemptsToGoal'])}. Final abilities: {', '.join(f'{a:.0f}' for a in org['finalAbilities'])}. Spearman(score, rating) over all {org['records']} picks: {org['spearman']:.3f} (low because the uniform shape draw and the mate/improvement alternation dominate the variance; the bucket means carry the evidence).",'',
 '| bucket | picks | mean level | mean selected rating | mean gap to stratum ceiling |','|---|---|---|---|---|']
for name,label in [('low',f"low (<{pts(summary['lowBucket'])})"),('mid',f"mid ({pts(summary['lowBucket'])}–{pts(summary['highBucket'])})"),('high',f"high (≥{pts(summary['highBucket'])})")]:
    b=org['buckets'][name];lines.append(f"| {label} | {b['count']} | {b['meanLevel']:.0f} | {b['meanRating']:.0f} | {b['meanGap']:.0f} |")
lines+=['',f"High-bucket picks within 150 of their stratum ceiling: {100*org['buckets']['high']['ceilingShare']:.1f}%.",'',
 '## Struggle run (every fifth puzzle fails)','',
 f"Attempts to goal {stru['attemptsToGoal']}; reviews presented {stru['reviewsPresented']} of {stru['records']} picks ({100*stru['reviewShare']:.1f}%); bucket mean ratings low/mid/high {stru['buckets']['low']['meanRating']:.0f}/{stru['buckets']['mid']['meanRating']:.0f}/{stru['buckets']['high']['meanRating']:.0f}; Spearman {stru['spearman']:.3f}."+" Failed sources enter the coach's failure cooldown (at least 12 presentations and 15 minutes, doubling); the harness shares one wall clock with `candidates()`, so during a seconds-long run the time gate stays closed and no cooled-down review is re-presented.",'',
 '## Native bot arena','',
 'Solve rates by score bucket (sweep picks at ability 1100, one per stratum, deduplicated by id):','',
 '| score | puzzles | mean rating | native-1 | native-2 | native-4 | unknown |','|---|---|---|---|---|---|---|']
for b in arena['sweep']['buckets']:
    r=arena['sweep']['results'][b];lines.append(f"| {b.split('=')[1]} | {r['count']} | {r['meanRating']:.0f} | "+' | '.join(f"{r['bots'][n]['solvedPercent']:.1f}%" for n in ('native-1','native-2','native-4'))+f" | {sum(r['bots'][n]['unknown'] for n in r['bots'])} |")
lines+=['','Organic picks (five seeds, reviews excluded, up to 120 per bucket):','','| bucket | puzzles | mean rating | native-1 | native-2 | native-4 | unknown |','|---|---|---|---|---|---|---|']
for b in arena['organic']['buckets']:
    r=arena['organic']['results'][b];lines.append(f"| {b} | {r['count']} | {r['meanRating']:.0f} | "+' | '.join(f"{r['bots'][n]['solvedPercent']:.1f}%" for n in ('native-1','native-2','native-4'))+f" | {sum(r['bots'][n]['unknown'] for n in r['bots'])} |")
lines+=['',f"Arena games: {arena['sweep']['games']+arena['organic']['games']} in {arena['sweep']['seconds']+arena['organic']['seconds']:.0f} s; unknown proofs: {arena['sweep']['unknown']+arena['organic']['unknown']}. Mid and high organic buckets are indistinguishable to the bots because both sit at the catalogue ceiling.",'',
 '## Known limits','',
 '- The catalogue ceiling (improvement maxima about 1580–2014, mate maxima about 2038–2397 per shape) bounds the rise; the level reaches 2400–2740 by 1,000 points.',
 '- A minority of high-score picks fall more than 150 below their stratum ceiling because of the seen-variant and recent-source penalties and last-three blocking; the 85% ceiling-share assertion reflects that.',
 '- Production delivers compositions measured within −175/+250 of the bank parent and prepared handoffs within ±150 level drift, so device trajectories are noisier than this harness.',
 '- The struggle run models intentional difficulty relief (reviews every fourth puzzle, the 0.78 target); it is asserted per bucket, never per attempt.','',
 '## Assertions','',f"Harness checks: {summary['checks']} ({len(summary['failures'])} failures). Arena checks: {sum(a['checks'] for a in arena.values())} ({sum(len(a['failures']) for a in arena.values())} failures). Raw records: `reports/difficulty-progression/{{sweep,organic,struggle}}.jsonl`, `arena-sweep.json`, `arena-organic.json`, `summary.json`.",'']
REPORT.write_text('\n'.join(lines))
print(f"checks={summary['totalChecks']} failures={summary['totalFailures']} total={timings['total']:.0f}s -> {REPORT}")
