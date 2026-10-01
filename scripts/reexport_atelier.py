"""Re-export unchanged editable .blend sources after export/LOD improvements."""
import sys,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
import build_atelier as a
for t in a.THEMES:
    a.bpy.ops.wm.open_mainfile(filepath=str(a.ART/f'{t[0]}-atelier.blend'))
    stats=[]
    for kind in 'PNBRQK':
        o=a.bpy.data.objects[f'{t[0]}-{kind}']
        high=a.export(o,a.OUT/f'{t[0]}-{kind}.ccmesh')
        low=a.export(o,a.OUT/f'{t[0]}-{kind}-lod.ccmesh',.25 if t[0]>120 else (.34 if t[0]>100 else .43))
        stats.append({'theme':t[0],'piece':kind,'high':high,'low':low})
    frame=next(o for o in a.bpy.data.objects if o.name.startswith(f'{t[0]}-frame.'))
    a.export(frame,a.OUT/f'{t[0]}-frame.ccmesh')
    (a.OUT/f'{t[0]}-manifest.json').write_text(json.dumps(stats,indent=2))
    print('EXPORTED',t[0],flush=True)
