#!/usr/bin/env python3
"""Build the bundled Stockfish source for iPhone, simulator and host regression tests."""
import argparse,concurrent.futures,subprocess,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'NativeEngine/Stockfish'
SOURCES='attacks benchmark bitboard evaluate misc movegen movepick position search thread timeman tt uci ucioption tune syzygy/tbprobe nnue/nnue_accumulator nnue/nnue_misc nnue/network nnue/features/half_ka_v2_hm nnue/features/full_threats nnue/features/pp_3wide engine score memory'.split()

def build(sdk,dotprod=False):
 target={'iphoneos':'arm64-apple-ios17.0','iphonesimulator':'arm64-apple-ios17.0-simulator','macosx':'arm64-apple-macos14.0'}[sdk]
 sysroot=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
 compiler=subprocess.check_output(['xcrun','--sdk',sdk,'--find','clang++'],text=True).strip()
 out=ROOT/'NativeEngine/lib'/sdk/('dotprod' if dotprod else '.');out.mkdir(parents=True,exist_ok=True)
 flags=['-target',target,'-isysroot',sysroot,'-std=c++17','-O3','-DNDEBUG','-DIS_64BIT','-DUSE_NEON=8','-DUSE_POPCNT','-DNNUE_EMBEDDING_OFF','-fno-exceptions','-I',str(SRC)]
 if dotprod:flags+=['-march=armv8.2-a+dotprod','-DUSE_NEON_DOTPROD','-DStockfish=StockfishDotprod']
 signature=json.dumps([compiler,*flags]);stamp=out/'build-flags.json'
 rebuild=not stamp.exists() or stamp.read_text()!=signature
 # Header and compiler-flag changes must invalidate objects too.
 newest_header=max(p.stat().st_mtime for p in SRC.rglob('*.h'))
 def compile(name):
  source=SRC/(name+'.cpp');obj=out/(name.replace('/','_')+'.o')
  if rebuild or not obj.exists() or max(source.stat().st_mtime,newest_header)>obj.stat().st_mtime:
   subprocess.run([compiler,*flags,'-c',str(source),'-o',str(obj)],check=True)
  return str(obj)
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:objects=list(pool.map(compile,SOURCES))
 library=out.parent/'libStockfishDotprod.a' if dotprod else out/'libStockfish.a'
 subprocess.run(['xcrun','libtool','-static','-o',str(library),*objects],check=True)
 stamp.write_text(signature)
 print(sdk+(' dot-product' if dotprod else ' baseline')+' Stockfish library ready.',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--sdk',choices=['iphoneos','iphonesimulator','macosx'],action='append');a=p.parse_args()
 for sdk in a.sdk or ['iphoneos','iphonesimulator','macosx']:
  build(sdk);build(sdk,dotprod=True)
