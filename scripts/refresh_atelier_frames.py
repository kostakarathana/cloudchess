"""Refresh editable board friezes and photographs, preserving piece sculpts."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
import build_atelier as a
for t in a.THEMES:
    a.bpy.ops.wm.open_mainfile(filepath=str(a.ART/f'{t[0]}-atelier.blend'))
    old=[o for o in a.bpy.data.objects if o.name.startswith(f'{t[0]}-frame.')]
    frame=a.board_module(t,a.materials(t,False))
    a.export(frame,a.OUT/f'{t[0]}-frame.ccmesh')
    for o in old:o.data=frame.data
    a.bpy.data.objects.remove(frame,do_unlink=True)
    a.bpy.ops.wm.save_as_mainfile(filepath=str(a.ART/f'{t[0]}-atelier.blend'),compress=True)
    print('FRAME',t[0],flush=True)
(a.ART/'frames-ready').write_text('complete')
for t in a.THEMES:
    a.bpy.ops.wm.open_mainfile(filepath=str(a.ART/f'{t[0]}-atelier.blend'))
    a.bpy.context.scene.render.filepath=str(a.ART/f'{t[0]}-board.png')
    a.bpy.ops.render.render(write_still=True)
    print('PHOTO',t[0],flush=True)
