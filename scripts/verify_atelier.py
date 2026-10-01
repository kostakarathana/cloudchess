"""Validate shipped Blender mesh ABI, mobile budgets, uniqueness and LOD coverage."""
from pathlib import Path
import json, struct, hashlib
import numpy as np
ROOT=Path(__file__).resolve().parents[1];assets=ROOT/'CloudChess/EngineResources/Atelier'
ids=[*range(1,11),101,102,103,104,105,121,122]
checks=0;records=[]
def check(condition,label):
    global checks
    assert condition,label
    checks+=1

def read(path,piece):
    data=path.read_bytes();magic,n,*rest=struct.unpack('<4s6I',data[:28]);counts,version=rest[:4],rest[4]
    check(magic==b'CCA1' and version==1,str(path))
    check(len(data)==28+n*24+sum(counts)*4,'Exact buffer lengths')
    v=np.frombuffer(data,dtype='<f4',count=n*6,offset=28).reshape(-1,6)
    idx=np.frombuffer(data,dtype='<u4',offset=28+n*24)
    check(np.isfinite(v).all(),'Finite attributes')
    check(len(idx)%3==0 and int(idx.max())<n,'Valid indexed triangles')
    check(np.allclose(np.linalg.norm(v[:,3:],axis=1),1,atol=.012),'Unit normals')
    check(all(c%3==0 for c in counts),'Four complete material batches')
    if piece:
        check(v[:,1].min()>=-.001,'Planted sole')
        check(v[:,1].max()<1.3,'Compact sculpture')
        check(np.abs(v[:,0]).max()<.34 and v[:,2].min()>-.34 and v[:,2].max()<.36,'Fits cell and physically contained reward envelope')
        check(len(idx)//3<200000,'High-detail geometry budget')
    return {'name':path.stem,'vertices':n,'triangles':len(idx)//3,'bytes':len(data),'hash':hashlib.sha256(data).hexdigest()}
for id in ids:
    for kind in 'PNBRQK':
        high=read(assets/f'{id}-{kind}.ccmesh',True);low=read(assets/f'{id}-{kind}-lod.ccmesh',True)
        check(low['triangles']<high['triangles']*.48 and low['triangles']<55000,'Effective bounded distance LOD')
        check(high['triangles']>25000,'Authored detailed mesh rather than primitive fallback')
        records.append(high);records.append(low)
    records.append(read(assets/f'{id}-frame.ccmesh',False))
    for texture in ['light','dark','normal','rough']:
        data=(assets/f'{id}-{texture}.png').read_bytes()
        check(data[:8]==b'\x89PNG\r\n\x1a\n','Valid texture')
        check(struct.unpack('>II',data[16:24])==(512,512),'Texture dimensions')
    check((ROOT/f'art/atelier/{id}-atelier.blend').exists(),'Editable Blender source')
    check((ROOT/f'art/atelier/{id}-portrait.png').exists(),'Actual model render')
check(len({r['hash'] for r in records})==len(records),'Every exported model is geometrically distinct')
report={'status':'passed','checks':checks,'collections':len(ids),'sculptures':len(ids)*6,'sideVariants':len(ids)*12,'meshFiles':len(records),'meshBytes':sum(r['bytes'] for r in records),'highestTriangles':max(r['triangles'] for r in records),'records':records}
(ROOT/'reports/atelier-v10/mesh-verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='records'},indent=2))
