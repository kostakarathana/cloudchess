"""CloudChess Atelier. Original authored meshes, offline Blender 4.5 asset pipeline.
Run Blender --background --python scripts/build_atelier.py -- [theme IDs].
Coordinates: Blender Z-up; export converts to SceneKit Y-up. Four batched material
slots; no runtime subdivision, CSG, procedural construction or texture synthesis.
"""
import bpy, math, struct, json, sys, hashlib, time
import numpy as np
from pathlib import Path
from mathutils import Vector
from math import sin, cos, pi, sqrt
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'CloudChess/EngineResources/Atelier'; OUT.mkdir(parents=True,exist_ok=True)
ART=ROOT/'art/atelier'; ART.mkdir(parents=True,exist_ok=True)
THEMES=[
(1,'Thunderhead','E1F1F5','183649','72D8FF'),(2,'Midnight Borough','D4E0E9','18243C','FFCC74'),
(3,'Tidepool Aquarium','DBF5EA','176879','FF9C86'),(4,'Lantern Grove','EBDDBF','365C49','E8B365'),
(5,'Lunar Expedition','E5E9F1','42536C','FA9867'),(6,'Sugar Workshop','FFE8DA','9B4264','8ADBC7'),
(7,"Clockmaker's Desk",'F5E3B9','3C5158','C58A43'),(8,'Porcelain Pagoda','F4ECD8','365E8F','EC9B72'),
(9,'Tidal Forge','E8CDBB','343745','FF7844'),(10,'Winter Filigree','E7F9FF','32608A','A6EAFF'),
(101,'Celestial Conservatory','F1E5FA','5D397D','C4E998'),(102,"Leviathan's Archive",'D7F7ED','144A63','75F6D1'),
(103,'Phoenix Court','FFE4CA','781D39','F5AD4E'),(104,'Nocturne Cathedral','E9E4DD','273449','B6A5EC'),
(105,'Jade Dynasty','E4F1D5','164F46','E8BE70'),(121,'Astral Orrery','EBE7FF','372357','F1BD79'),
(122,'Dragon Sovereign','FFF0D3','451C35','ED9855')]

def color(hex):
    srgb=[int(hex[i:i+2],16)/255 for i in (0,2,4)]
    return tuple(((v+.055)/1.055)**2.4 if v>.04045 else v/12.92 for v in srgb)
def materials(t,white=True):
    result=[]
    for i,(name,col,metal,rough) in enumerate([
        ('Body',t[2] if white else t[3],.18 if t[0] in [1,2,5,7,9,121,122] else .035,.25),
        ('Inlaid metal',t[4],.72,.26),('Recess',t[3] if white else '101723',.12,.40),
        ('Enamel',t[4],.15,.18)]):
        m=bpy.data.materials.new(name); m.diffuse_color=(*color(col),1);m.use_nodes=True
        p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=m.diffuse_color;p.inputs['Metallic'].default_value=metal;p.inputs['Roughness'].default_value=rough
        p.inputs['Coat Weight'].default_value=.28
        result.append(m)
    return result

class Sculpt:
    def __init__(self):self.v=[];self.f=[];self.mi=[]
    def mesh(self,vs,fs,mat=0):
        off=len(self.v);self.v.extend(vs);self.f.extend(tuple(off+i for i in f) for f in fs);self.mi.extend([mat]*len(fs))
    def surface(self,fn,nu,nv,mat=0,wrap=True,reverse=False):
        vs=[fn(i/nu,j/nv) for j in range(nv+1) for i in range(nu if wrap else nu+1)]
        stride=nu if wrap else nu+1;fs=[]
        for j in range(nv):
            for i in range(nu):
                a=j*stride+i;b=j*stride+(i+1)%stride;c=b+stride;d=a+stride
                fs.append((d,c,b,a) if reverse else (a,b,c,d))
        self.mesh(vs,fs,mat)
    def lathe(self,profile,mat=0,flutes=0,amp=0,twist=0,sides=80):
        # Interpolated profile retains hand-cut collars without faceting the silhouette.
        p=[]
        for a,b in zip(profile,profile[1:]):
            for k in range(3):
                u=k/3;p.append((a[0]*(1-u)+b[0]*u,a[1]*(1-u)+b[1]*u))
        p.append(profile[-1]);vs=[]
        for r,z in p:
            for i in range(sides):
                a=2*pi*i/sides;rr=r*(1+amp*cos(a*flutes+twist*z))
                vs.append((rr*cos(a),rr*sin(a),z))
        fs=[]
        for j in range(len(p)-1):
            for i in range(sides):
                a=j*sides+i;b=j*sides+(i+1)%sides;fs.append((a,b,b+sides,a+sides))
        fs.extend([tuple(reversed(range(sides))),tuple((len(p)-1)*sides+i for i in range(sides))]);self.mesh(vs,fs,mat)
    def tube(self,points,r=.009,mat=1,sides=7,closed=False):
        pts=[Vector(p) for p in points];vs=[]
        for i,p in enumerate(pts):
            tangent=pts[(i+1)%len(pts)]-pts[(i-1)%len(pts)] if closed else pts[min(i+1,len(pts)-1)]-pts[max(0,i-1)]
            tangent.normalize();axis=Vector((0,0,1)) if abs(tangent.z)<.92 else Vector((1,0,0));u=tangent.cross(axis).normalized();v=tangent.cross(u).normalized()
            radius=float(r if isinstance(r,(int,float)) else r[i])
            for j in range(sides):vs.append(tuple(p+radius*(u*cos(j*2*pi/sides)+v*sin(j*2*pi/sides))))
        fs=[]
        for i in range(len(pts) if closed else len(pts)-1):
            for j in range(sides):
                a=i*sides+j;b=i*sides+(j+1)%sides;c=((i+1)%len(pts))*sides+(j+1)%sides;d=((i+1)%len(pts))*sides+j;fs.append((a,b,c,d))
        if not closed:fs.extend([tuple(reversed(range(sides))),tuple((len(pts)-1)*sides+i for i in range(sides))])
        self.mesh(vs,fs,mat)
    def ring(self,r,z,mat=1,tube=.008,wave=0,n=0,phase=0):
        self.tube([((r+wave*cos(n*a))*cos(a),(r+wave*cos(n*a))*sin(a),z) for a in np.linspace(0,2*pi,96,endpoint=False)],tube,mat,closed=True)
    def bead(self,center,scale,mat=1,seg=12):
        self.surface(lambda u,v:(center[0]+scale[0]*sin(pi*v)*cos(2*pi*u),center[1]+scale[1]*sin(pi*v)*sin(2*pi*u),center[2]+scale[2]*cos(pi*v)),seg,8,mat,reverse=True)
    def leaf(self,origin,direction,length,width,mat=0,veins=True):
        # Raised lanceolate relief with curled tip, axial ridge and chased veins.
        o=Vector(origin);d=Vector(direction).normalized();normal=Vector((origin[0],origin[1],.15)).normalized()
        w=d.cross(normal).normalized();normal=w.cross(d).normalized()
        def pos(u,v):
            s=sin(pi*v)**.72;across=2*u-1
            return tuple(o+d*(v*length)+w*(across*width*s)+normal*(.014*(1-across*across)*s+.013*v*v))
        vs=[pos(i/6,j/12) for j in range(13) for i in range(7)]
        lower=[tuple(Vector(v)-normal*.0035) for v in vs];faces=[];n=len(vs)
        for j in range(12):
            for i in range(6):
                aa=j*7+i;bb=aa+1;cc=bb+7;dd=aa+7;faces.extend([(aa,bb,cc,dd),(dd+n,cc+n,bb+n,aa+n)])
        border=list(range(7))+[j*7+6 for j in range(1,13)]+list(range(89,83,-1))+[j*7 for j in range(11,0,-1)]
        for a,b in zip(border,border[1:]+border[:1]):faces.append((a,a+n,b+n,b))
        self.mesh(vs+lower,faces,mat)
        self.tube([pos(.5,v) for v in np.linspace(0,.95,12)],.0026,1 if mat==0 else mat,sides=5)
        if veins:
            for v in [.22,.38,.54,.70]:
                for sign in [-1,1]:self.tube([pos(.5+sign*.45*u,v+.12*u) for u in np.linspace(0,1,5)],.0018,mat,sides=4)
    def box(self,center,size,mat=0,bevel=.008):
        # Offline beveled boxes for architectural joinery, never unrounded primitives.
        bpy.ops.mesh.primitive_cube_add(size=1,location=center);o=bpy.context.object;o.scale=size;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
        b=o.modifiers.new('Hand eased edges','BEVEL');b.width=bevel;b.segments=3
        dg=bpy.context.evaluated_depsgraph_get();e=o.evaluated_get(dg);m=e.to_mesh();self.mesh([tuple(o.matrix_world@v.co) for v in m.vertices],[tuple(p.vertices) for p in m.polygons],mat);e.to_mesh_clear();bpy.data.objects.remove(o,do_unlink=True)
    def object(self,name,mats):
        mesh=bpy.data.meshes.new(name);mesh.from_pydata(self.v,[],self.f);mesh.update()
        obj=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(obj)
        for m in mats:mesh.materials.append(m)
        for p,i in zip(mesh.polygons,self.mi):p.material_index=i;p.use_smooth=True
        return obj

def scroll(s,angle,z,r=.2,scale=.055,mat=1,turns=1.25):
    # A jeweller's spiral in the tangent plane of the body.
    pts=[]
    for u in np.linspace(0,1,36):
        a=u*2*pi*turns;rr=scale*(1-.84*u);x=rr*cos(a);y=rr*sin(a)
        pts.append((r*cos(angle)-x*sin(angle),r*sin(angle)+x*cos(angle),z+y))
    s.tube(pts,.0038,mat,6)

def band(s,z,r,theme):
    s.ring(r,z-.012);s.ring(r,z+.012)
    n=32 if theme<100 else 48
    for j in range(n):
        a=j*2*pi/n
        if theme in [3,102,105,122]:
            pts=[((r+.002*cos(pi*u))*cos(a+.034*sin(pi*u)),(r+.002*cos(pi*u))*sin(a+.034*sin(pi*u)),z+.012*cos(pi*u)) for u in np.linspace(0,1,7)]
            s.tube(pts,.0036,1,5)
        else:
            s.tube([(r*cos(a),r*sin(a),z-.008),(r*cos(a+.024),r*sin(a+.024),z+.008)],.004,1,5)

def body(s,t,kind):
    id=t[0];h={'P':.37,'R':.48,'N':.26,'B':.54,'Q':.57,'K':.60}[kind]
    # Foot has three separately chased mouldings and a recessed ornamental belt.
    flute={1:(12,.052,3),2:(8,.075,0),3:(18,.07,4),4:(9,.12,15),5:(12,.025,0),6:(16,.08,8),7:(24,.035,0),8:(8,.065,0),9:(7,.1,12),10:(12,.055,0),101:(10,.11,10),102:(14,.095,8),103:(16,.08,10),104:(8,.13,0),105:(12,.055,7),121:(18,.03,0),122:(10,.12,13)}[id]
    s.lathe([(.03,.006),(.235,.006),(.271,.016),(.289,.038),(.288,.054),(.276,.066),(.26,.072),(.262,.106),(.274,.113),(.268,.129),(.232,.15),(.195,.167)],flutes=flute[0],amp=flute[1]*.4)
    band(s,.09,.266,id)
    for j in range(24 if id<100 else 40):
        a=j*2*pi/(24 if id<100 else 40)
        scroll(s,a,.121,.258,.010,1,1.15)
    s.ring(.279,.044,tube=.006);s.ring(.244,.143,tube=.006)
    for j in range(12 if id<100 else 18):
        a=j*2*pi/(12 if id<100 else 18);s.bead((.269*cos(a),.269*sin(a),.092),(.006,.006,.008),3,8)
    if id==2:
        for j,(w,z,d) in enumerate([(.32,.20,.08),(.28,.30,.14),(.225,.43,.14)]):
            if z>h:break
            s.box((0,0,z),(w,w,d),0,.015)
            for side in [-1,1]:
                for k in [-1,0,1]:
                    s.box((k*w*.24,side*(w/2+.002),z),(.015,.008,d*.72),3,.003)
        s.lathe([(.15,.16),(.105,h-.015),(.17,h)],flutes=8,amp=.10,sides=64)
    elif id==7:
        s.lathe([(.13,.16),(.072,.21),(.063,h-.04),(.15,h)],flutes=12,amp=.06)
        for z,r in [(.20,.167),(h-.055,.15)]:
            s.lathe([(r-.02,z-.016),(r,z-.011),(r,z+.011),(r-.02,z+.016)],1,flutes=24,amp=.07)
            for j in range(8):
                a=j*pi/4;s.tube([(.05*cos(a),.05*sin(a),z),(.14*cos(a),.14*sin(a),z)],.007,1)
        for j in range(6):
            a=j*pi/3;s.tube([(.155*cos(a),.155*sin(a),.18),(.12*cos(a),.12*sin(a),h)],.009,1)
        for z in np.arange(.24,h-.05,.022):s.ring(.075,z,tube=.0035)
    elif id in [101,104,121]:
        s.lathe([(.15,.16),(.092,.21),(.07,h-.05),(.142,h)],flutes=8,amp=.05)
        for j in range(8):
            a=j*pi/4;pts=[]
            for u in np.linspace(0,1,25):
                r=.165-.042*sin(pi*u);pts.append((r*cos(a+.13*sin(pi*u)),r*sin(a+.13*sin(pi*u)),.17+(h-.17)*u))
            s.tube(pts,.012 if id==104 else .008,1)
            if id==101:
                s.leaf((.155*cos(a),.155*sin(a),.24),(.28*cos(a),.28*sin(a),1),.20,.05,0)
            if id==104:
                for k in [-1,1]:
                    s.tube([((.135+.04*sin(pi*u))*cos(a+k*.21*sin(pi*u)),(.135+.04*sin(pi*u))*sin(a+k*.21*sin(pi*u)),.23+(h-.23)*u) for u in np.linspace(0,1,22)],.0045,1)
    else:
        profiles={
         3:[(.195,.16),(.177,.2),(.109,h*.70),(.115,h-.035),(.17,h)],
         4:[(.195,.16),(.14,.22),(.104,h*.78),(.13,h)],
         6:[(.19,.16),(.188,.22),(.15,.235),(.147,h-.07),(.18,h-.05),(.17,h)],
         8:[(.195,.16),(.15,.205),(.13,h-.11),(.185,h-.08),(.19,h-.06),(.117,h-.03),(.15,h)],
         9:[(.195,.16),(.172,.22),(.105,h-.1),(.152,h)],
         102:[(.195,.16),(.135,.23),(.115,h-.1),(.19,h)],
         103:[(.195,.16),(.148,.24),(.10,h-.09),(.17,h)],
         105:[(.195,.16),(.14,.24),(.13,h-.07),(.17,h)],
         122:[(.195,.16),(.138,.25),(.095,h-.1),(.18,h)]}
        profile=profiles.get(id,[(.195,.16),(.17,.19),(.133,.24),(.102,h-.07),(.129,h-.035),(.172,h)])
        # Knight's short pedestal must be monotonic before its continuous sculpted neck.
        if kind=='N':profile=[(.195,.16),(.181,.18),(.17,.215),(.178,.24),(.163,h)]
        s.lathe(profile,flutes=flute[0],amp=flute[1],twist=flute[2])
    s.ring(.165,h,tube=.009);s.ring(.155,h-.023,tube=.006)
    if kind!='N':
        n=8 if id<100 else 12
        for j in range(n):
            a=j*2*pi/n
            if id in [3,4,101,102,103,105,122]:
                for layer in range(2 if id<100 else 3):
                    z=.18+layer*(h-.21)/3;r=.17-layer*.025
                    s.leaf((r*cos(a),r*sin(a),z),(cos(a)*-.15,sin(a)*-.15,1),min(.18,h-z),.034 if id<100 else .045,0)
            elif id in [1,5,6,8,9,10]:
                for z in [.205,h-.07]:scroll(s,a,z,.145,.035,1,.85)
    if kind!='N' and id in [1,5,8,10]:
        for j in range(8):
            a=j*pi/4
            s.leaf((.162*cos(a),.162*sin(a),.19),(-.2*cos(a),-.2*sin(a),1),min(.17,h-.18),.022,0)
    if id in [5,8,10,105]:
        band(s,h-.046,.149,id)
    if id in [1,9]:
        for j in range(6):
            a=j*pi/3;s.tube([(.17*cos(a),.17*sin(a),.20),(.121*cos(a+.08),.121*sin(a+.08),h*.72),(.136*cos(a-.09),.136*sin(a-.09),h*.76),(.16*cos(a),.16*sin(a),h)],.004,3)
    if id==6:
        for j in range(16):
            a=j*pi/8;s.tube([((.17+.015*sin(pi*u))*cos(a),(.17+.015*sin(pi*u))*sin(a),h-.02-.055*sin(pi*u)) for u in np.linspace(0,1,9)],.006,1)
    if id in [121,122]:
        for j in range(12):
            a=j*pi/6;scroll(s,a,.13,.242,.031,1,1.65)
    return h

def horse(s,t,h):
    # Organic neck and face are authored sectional surfaces, then unified in Blender.
    organic=Sculpt()
    sections=[(-.035,.27,.135,.13),(-.08,.36,.13,.14),(-.105,.48,.115,.15),(-.11,.60,.115,.14),(-.075,.72,.132,.115),(-.015,.80,.14,.106),(.10,.805,.14,.087),(.215,.745,.085,.075),(.263,.715,.06,.058)]
    for seq in [sections]:
        vs=[];ns=40
        # Smooth center/elliptical cross sections, long axis in XZ plane.
        for j,(x,z,rx,ry) in enumerate(seq):
            for a in np.linspace(0,2*pi,ns,endpoint=False):vs.append((x+rx*cos(a),ry*sin(a),z+.075*cos(a)))
        fs=[]
        for j in range(len(seq)-1):
            for i in range(ns):a=j*ns+i;b=j*ns+(i+1)%ns;fs.append((a,b,b+ns,a+ns))
        fs.extend([tuple(reversed(range(ns))),tuple((len(seq)-1)*ns+i for i in range(ns))]);organic.mesh(vs,fs)
    o=organic.object('sculpting horse',materials(t));bpy.context.view_layer.objects.active=o;o.select_set(True)
    sub=o.modifiers.new('Sculpt surface','SUBSURF');sub.levels=2;bpy.ops.object.modifier_apply(modifier=sub.name)
    s.mesh([tuple(v.co) for v in o.data.vertices],[tuple(p.vertices) for p in o.data.polygons]);bpy.data.objects.remove(o,do_unlink=True)
    # Ears with a genuinely hollow interior, almond eyes, jaw line and nostrils.
    for side in [-1,1]:
        s.leaf((-.040,side*.043,.775),(-.12,side*.22,1),.163,.031,0)
        s.leaf((-.033,side*.044,.811),(-.12,side*.22,1),.08,.015,2,False)
        s.bead((.09,side*.094,.827),(.024,.009,.018),2,16)
        s.bead((.094,side*.103,.829),(.008,.004,.01),1,12)
        s.tube([(.045+.039*cos(a),side*(.096+.004*sin(a)),.826+.025*sin(a)) for a in np.linspace(0,pi,15)],.0045,0)
        s.bead((.263,side*.050,.75),(.014,.007,.009),2,12)
        s.tube([(.11,side*.085,.738),(.18,side*.081,.70),(.25,side*.052,.694)],.0035,2)
        s.tube([(-.02,side*.109,.835),(.04,side*.112,.78),(.12,side*.092,.735),(.19,side*.080,.72)],.007,1)
        s.bead((.075,side*.105,.76),(.018,.006,.018),1,12)
    # Overlapping carved mane feathers, not a row of cubes.
    count=12 if t[0]<100 else 19
    for j in range(count):
        u=j/(count-1);z=.34+.43*u;x=-.13-.062*sin(pi*u)
        for side in [-1,1]:
            s.leaf((x,side*.055,z),(-.55,side*.30,-.75),.093,.028,1 if t[0] in [7,121] else 0)
    for side in [-1,1]:
        for i in range(4 if t[0]<100 else 7):
            z=.36+i*.046
            s.tube([(-.07+.058*cos(a),side*(.135-.02*sin(a)),z+.033*sin(a)) for a in np.linspace(-.3,pi,18)],.0035,1)
    if t[0] in [103,122]:
        for side in [-1,1]:
            for i in range(7):s.leaf((-.12,side*.08,.37+i*.035),(-.45,side*.75,.5),.15,.033,1)
    if t[0] in [5,2]:
        for side in [-1,1]:s.tube([(-.18,side*.12,.42),(-.18,side*.12,.69),(-.06,side*.12,.85),(.12,side*.1,.84)],.008,1)

def head(s,t,kind,h):
    id=t[0]
    if kind=='N':horse(s,t,h);return
    if kind=='P':
        s.lathe([(.135,h),(.145,h+.027),(.119,h+.043),(.074,h+.06)],1)
        # Fluted orb, little carved collar and engraved cap.
        s.surface(lambda u,v:((.126+.003*cos(u*24*pi)*sin(pi*v))*sin(pi*v)*cos(2*pi*u),(.126+.003*cos(u*24*pi)*sin(pi*v))*sin(pi*v)*sin(2*pi*u),h+.168+.128*cos(pi*v)),64,32,0,reverse=True)
        for j in range(6):
            a=j*pi/3;s.tube([(.13*sin(v)*cos(a),.13*sin(v)*sin(a),h+.168+.13*cos(v)) for v in np.linspace(.3,1.4,18)],.003,1)
    elif kind=='R':
        s.lathe([(.175,h),(.20,h+.03),(.211,h+.052),(.21,h+.08),(.194,h+.105),(.197,h+.21),(.153,h+.21),(.15,h+.07)],0,flutes=16,amp=.025)
        band(s,h+.07,.213,id)
        for j in range(6):
            a=j*pi/3;vs=[];fs=[]
            for z,r in [(h+.19,.153),(h+.19,.204),(h+.29,.204),(h+.29,.153)]:
                for q in range(9):aa=a+(q/8-.5)*.64;vs.append((r*cos(aa),r*sin(aa),z))
            for k in range(4):
                for q in range(8):fs.append((k*9+q,k*9+q+1,((k+1)%4)*9+q+1,((k+1)%4)*9+q))
            fs.extend([(0,9,18,27),(8,35,26,17)]);s.mesh(vs,fs)
            s.tube([(.209*cos(a+d),.209*sin(a+d),h+.275) for d in np.linspace(-.30,.30,12)],.006,1)
        # Recessed masonry arrowslits.
        for j in range(12):
            a=j*pi/6;s.tube([(.199*cos(a),.199*sin(a),h+.12),(.199*cos(a),.199*sin(a),h+.185)],.009,2)
    elif kind=='B':
        s.lathe([(.165,h),(.19,h+.025),(.19,h+.04),(.126,h+.062),(.09,h+.075)],1)
        # Slit mitre: full 3D teardrop with a diagonal cut, not a painted stripe.
        q=Sculpt();q.lathe([(.015,h+.055),(.108,h+.076),(.162,h+.13),(.16,h+.20),(.12,h+.275),(.073,h+.34),(.01,h+.395)],flutes=12,amp=.018)
        obj=q.object('mitre',materials(t));bpy.context.view_layer.objects.active=obj
        bpy.ops.mesh.primitive_cube_add(size=1,location=(.065,0,h+.295));cut=bpy.context.object;cut.scale=(.038,.55,.30);cut.rotation_euler.y=-.68
        bpy.context.view_layer.objects.active=obj;mod=obj.modifiers.new('Carved mitre slit','BOOLEAN');mod.operation='DIFFERENCE';mod.object=cut
        bpy.ops.object.modifier_apply(modifier=mod.name)
        s.mesh([tuple(v.co) for v in obj.data.vertices],[tuple(p.vertices) for p in obj.data.polygons]);bpy.data.objects.remove(cut,do_unlink=True);bpy.data.objects.remove(obj,do_unlink=True)
        for j in range(8):
            a=j*pi/4;s.leaf((.113*cos(a),.113*sin(a),h+.08),(.1*cos(a),.1*sin(a),1),.12,.025,1,False)
        s.bead((0,0,h+.393),(.025,.025,.028),1)
    elif kind=='Q':
        s.lathe([(.14,h),(.188,h+.025),(.184,h+.054),(.123,h+.075),(.144,h+.135),(.176,h+.192),(.156,h+.20),(.104,h+.08)],flutes=10,amp=.025)
        band(s,h+.04,.186,id)
        for j in range(8):
            a=j*pi/4;pts=[((.129+.064*u)*cos(a),(.129+.064*u)*sin(a),h+.115+.17*u) for u in np.linspace(0,1,14)]
            s.tube(pts,[.015-.009*u for u in np.linspace(0,1,14)],1)
            s.bead((.193*cos(a),.193*sin(a),h+.289),(.018,.018,.022),3)
            s.tube([((.176+.017*sin(pi*u))*cos(a+u*pi/4),(.176+.017*sin(pi*u))*sin(a+u*pi/4),h+.265-.068*sin(pi*u)) for u in np.linspace(0,1,14)],.0045,1)
        s.lathe([(.06,h+.09),(.075,h+.18),(.055,h+.22),(.026,h+.27),(.01,h+.315)],0)
        s.bead((0,0,h+.332),(.036,.036,.037),1)
    elif kind=='K':
        s.lathe([(.14,h),(.19,h+.025),(.188,h+.05),(.125,h+.075),(.136,h+.115),(.132,h+.18),(.11,h+.22),(.053,h+.24)],flutes=8,amp=.045)
        band(s,h+.04,.19,id)
        for j in range(6):
            a=j*pi/3;s.tube([((.135-.075*u)*cos(a),(.135-.075*u)*sin(a),h+.10+.18*sin(u*pi/2)) for u in np.linspace(0,1,18)],.008,1)
            s.bead((.139*cos(a),.139*sin(a),h+.15),(.015,.015,.02),3)
        s.bead((0,0,h+.266),(.052,.052,.043),1)
        # Cross is pierced/chased with an enamel centre and flared ends.
        s.box((0,0,h+.357),(.054,.061,.173),0,.009)
        s.box((0,0,h+.37),(.172,.061,.048),0,.009)
        for side in [-1,1]:
            s.tube([(0,side*.034,h+.287),(0,side*.034,h+.425)],.004,1)
            s.tube([(-.076,side*.034,h+.37),(.076,side*.034,h+.37)],.004,1)
            s.bead((0,side*.041,h+.371),(.017,.008,.017),3)
        for x,z in [(-.081,h+.37),(.081,h+.37),(0,h+.431)]:s.bead((x,0,z),(.027,.034,.024),1)

def extravagance(s,t,kind,h):
    id=t[0]
    if id==101:
        # Open petal canopy around the stem, with seed pearls.
        for j in range(10):
            a=j*pi/5;s.leaf((.19*cos(a),.19*sin(a),.17),(cos(a)*.45,sin(a)*.45,1),.27,.056,0)
            s.bead((.20*cos(a),.20*sin(a),.38),(.012,.012,.012),3)
    if id==102:
        for j in range(8):
            a=j*pi/4;pts=[]
            for u in np.linspace(0,1,36):
                r=.19+.045*sin(u*pi*2);aa=a+.48*sin(pi*u);z=.15+.22*u;pts.append((r*cos(aa),r*sin(aa),z))
            s.tube(pts,[.022*(1-.75*u) for u in np.linspace(0,1,36)],0,9)
            for u in [.15,.3,.45,.6,.75]:
                p=pts[int(u*35)];s.bead((p[0]*1.065,p[1]*1.065,p[2]),(.009,.009,.006),1,8)
    if id in [103,122]:
        for side in [-1,1]:
            for j in range(11 if id==122 else 8):
                u=j/10;s.leaf((side*.12,-.09,.18+u*.05),(side*(.6-u*.25),-.3,1),.27+.08*sin(pi*u),.027,1 if id==122 else 0)
    if id==104:
        for j in range(8):
            a=j*pi/4;s.tube([(.205*cos(a),.205*sin(a),.17),(.214*cos(a),.214*sin(a),.28),(.18*cos(a),.18*sin(a),.43)],.012,0)
            s.bead((.18*cos(a),.18*sin(a),.43),(.014,.014,.04),1)
    if id==105:
        for j in range(12):
            a=j*pi/6
            for z in [.18,.23,.28]:scroll(s,a,z,.175-(z-.18)*.35,.025,1,1.25)
    if id==121:
        # Three finely graduated intersecting gimbals and a constellation inlay.
        c=Vector((0,0,.31))
        for k in range(3):
            pts=[]
            for a in np.linspace(0,2*pi,100,endpoint=False):
                p=Vector((.231*cos(a),.231*sin(a),0));p.rotate(__import__('mathutils').Euler((.6+k*.7,k*.6,0)));pts.append(tuple(c+p))
            s.tube(pts,.0055,1,7,True)
            for j in range(0,100,10):s.bead(pts[j],(.009,.009,.009),3,8)
        for j in range(16):
            a=j*pi/8;s.tube([(.22*cos(a),.22*sin(a),.145),(.247*cos(a),.247*sin(a),.16)],.003,1)
    if id==122:
        for j in range(12):
            a=j*pi/6
            for layer in range(4):
                z=.17+layer*.036;r=.185-layer*.009
                s.leaf((r*cos(a),r*sin(a),z),(-.1*cos(a),-.1*sin(a),1),.058,.020,0)
        for side in [-1,1]:s.tube([(side*(.18+.035*sin(pi*u)),0,.20+.28*u) for u in np.linspace(0,1,24)],[.019*(1-.9*u) for u in np.linspace(0,1,24)],1)

def signature_carving(s,t,kind,h):
    """Theme-specific carving on the actual identifying head, not just its plinth."""
    id=t[0]
    if kind=='N':
        # The face and chest carry the same ornamental language as the royal pieces.
        for side in [-1,1]:
            for row in range(5 if id<100 else 8):
                for col in range(3):
                    z=.39+row*.035;x=-.15+col*.047
                    y=side*(.127-.014*col)
                    if id in [1,2,5,7,9,104]:
                        s.tube([(x-.017,y,z),(x,y+side*.006,z+.019),(x+.017,y,z)],.003,1,5)
                    else:
                        s.leaf((x,y,z),(.10,side*.35,1),.049,.016,0,False)
            if id in [2,5,7,104]:
                s.tube([(-.05,side*.108,.87),(.11,side*.112,.842),(.215,side*.08,.765)],.015,0,10)
                for j in range(6):s.tube([(-.01+j*.037,side*.116,.824-j*.009),(-.01+j*.037,side*.12,.853-j*.009)],.0028,1,5)
            if id in [3,102,105,122]:
                # Scalloped cheek plates, a curling sea/dragon crest.
                for j in range(7):
                    s.leaf((-.05+j*.023,side*.105,.82-j*.006),(-.3,side*.1,.8),.065,.015,0,False)
                pts=[(-.12-.075*sin(pi*u),side*.05,.78+.13*u) for u in np.linspace(0,1,24)]
                s.tube(pts,[float(.023*(1-.91*u)) for u in np.linspace(0,1,24)],1,8)
            if id in [4,101,103]:
                for j in range(6):s.leaf((-.09,side*.083,.68+j*.028),(-.75,side*.3,.8),.10,.022,0)
            if id==6:
                for j in range(6):s.bead((-.17,side*.025,.40+j*.065),(.036,.028,.033),1,12)
            if id==8:
                for j in range(5):
                    s.tube([(-.08+.16*u,side*(.116+.006*sin(pi*u)),.53+j*.041+.018*sin(pi*u)) for u in np.linspace(0,1,20)],.003,1)
            if id==10:
                for a in np.linspace(0,2*pi,6,endpoint=False):s.tube([(-.10,side*.135,.58),(-.10+.045*cos(a),side*.14,.58+.045*sin(a))],.003,1)
        return
    # Radial crest surfaces describe each crown's real envelope.
    cz=h+(.168 if kind=='P' else .17)
    radius=.127 if kind=='P' else (.143 if kind=='B' else .149)
    if id in [3,4,8,10,101,102,103,105,122]:
        count=10 if id<100 else 16
        for j in range(count):
            a=j*2*pi/count
            s.leaf((radius*cos(a),radius*sin(a),cz-.062),(-.45*cos(a),-.45*sin(a),1),.105,.022 if id<100 else .027,0)
    if id in [1,2,5,7,9,104]:
        for j in range(12):
            a=j*pi/6;scroll(s,a,cz,radius,.022,1,1.5 if id==7 else .8)
    if id==6:
        for j in range(12):
            a=j*pi/6;s.tube([((radius+.003*sin(pi*u))*cos(a+.08*u),(radius+.003*sin(pi*u))*sin(a+.08*u),cz-.035+.07*u) for u in np.linspace(0,1,12)],.006,1)
    if id==8 and kind=='R':
        # Four upturned glazed roof eaves below the crenellated tower.
        for j in range(4):
            a=j*pi/2
            s.tube([((.17+.10*u)*cos(a),(.17+.10*u)*sin(a),h+.065+.075*u*u) for u in np.linspace(0,1,16)],[.022-.012*float(u) for u in np.linspace(0,1,16)],0,9)
    if id==121:
        c=Vector((0,0,cz));rr=radius+.028
        for k in range(2):
            pts=[]
            for a in np.linspace(0,2*pi,72,endpoint=False):
                p=Vector((rr*cos(a),rr*sin(a),0));p.rotate(__import__('mathutils').Euler((.65+k*.8,k*.55,0)));pts.append(tuple(c+p))
            s.tube(pts,.0038,1,6,True)
    if id==122 and kind in 'KQBR':
        for j in range(8):
            a=j*pi/4
            s.tube([((.15+.048*sin(pi*u))*cos(a),(.15+.048*sin(pi*u))*sin(a),h+.05+.15*u) for u in np.linspace(0,1,16)],[.013*(1-.90*float(u)) for u in np.linspace(0,1,16)],1,7)

def sculpt_piece(t,kind,mats):
    s=Sculpt();h=body(s,t,kind);head(s,t,kind,h);extravagance(s,t,kind,h);signature_carving(s,t,kind,h)
    # Bend upper carving very slightly toward the camera; the sole remains flat.
    s.v=[(x,y-.11*max(0,z-.15),z) for x,y,z in s.v]
    o=s.object(f'{t[0]}-{kind}',mats)
    return o

def export(o,path,ratio=1):
    # Indexed, batched material groups. Export loop normals after offline evaluation.
    clone=o.copy();clone.data=o.data.copy();bpy.context.collection.objects.link(clone);bpy.context.view_layer.objects.active=clone
    if ratio<1:
        mod=clone.modifiers.new('Mobile distance LOD','DECIMATE');mod.ratio=ratio;bpy.ops.object.modifier_apply(modifier=mod.name)
    mesh=clone.data;mesh.calc_loop_triangles();mesh.update()
    vertices=[];lookup={};groups=[[] for _ in range(4)]
    for tri in mesh.loop_triangles:
        if tri.area<1e-14:continue
        for li in tri.loops:
            loop=mesh.loops[li];v=mesh.vertices[loop.vertex_index];n=mesh.corner_normals[li].vector
            if n.length_squared<1e-12:n=tri.normal
            n=n.normalized()
            x,y,z=v.co;nx,ny,nz=n
            record=(x,z,-y,nx,nz,-ny)
            key=tuple(round(float(q),6) for q in record)
            if key not in lookup:lookup[key]=len(vertices);vertices.append(record)
            groups[tri.material_index].append(lookup[key])
    vv=np.asarray(vertices,dtype='<f4');idx=np.asarray(sum(groups,[]),dtype='<u4')
    assert np.isfinite(vv).all() and len(idx)%3==0
    header=struct.pack('<4s6I',b'CCA1',len(vv),*[len(g) for g in groups],1)
    path.write_bytes(header+vv.tobytes()+idx.tobytes())
    result={'vertices':len(vv),'triangles':len(idx)//3,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bounds':[vv[:,:3].min(axis=0).tolist(),vv[:,:3].max(axis=0).tolist()]}
    bpy.data.objects.remove(clone,do_unlink=True);return result

def board_module(t,mats):
    s=Sculpt();id=t[0]
    # One repeatable 1-cell frieze: all ornament lies on the vertical edge.
    s.box((0,0,-.07),(1,.09,.20),0,.018)
    for z in [-.16,.02]:s.tube([(-.5,-.052,z),(.5,-.052,z)],.009,1)
    for j in range(5 if id<100 else 8):
        x=(j+.5)/(5 if id<100 else 8)-.5
        if id in [2,5,7,8,104]:
            for k in [-1,1]:s.tube([(x-.045,-.052,-.125),(x+k*.04,-.064,-.06),(x,-.056,-.012)],.0045,1)
            s.bead((x,-.06,-.065),(.009,.007,.012),3)
        else:
            pts=[(x+.045*cos(a),-.058,-.065+.047*sin(a)) for a in np.linspace(0,2*pi,30)]
            s.tube(pts,.004,1)
            for k in [-1,1]:s.tube([(x+k*.047*u,-.06,-.065+.038*sin(pi*u)) for u in np.linspace(0,1,16)],.003,1)
        if id>=100:s.bead((x,-.066,-.065),(.014,.008,.019),3)
    for j in range(8):
        x=(j+.5)/8-.5
        if id in [1,9]:
            s.tube([(x-.027,-.065,-.025),(x+.018,-.066,-.069),(x-.008,-.066,-.074),(x+.025,-.065,-.12)],.004,3)
        elif id in [3,4,101,102,103,105,122]:
            for k in range(3 if id<100 else 5):
                a=(k-1)*.5
                s.tube([(x+.04*cos(a)*u,-.066,-.12+.07*u) for u in np.linspace(0,1,12)],.003,1)
        elif id==6:
            s.tube([(x+.055*cos(a),-.062,-.06+.025*sin(a)) for a in np.linspace(0,2*pi,26)],.005,1)
        elif id==10:
            for a in np.linspace(0,2*pi,6,endpoint=False):s.tube([(x,-.067,-.07),(x+.025*cos(a),-.067,-.07+.025*sin(a))],.003,1)
        elif id==121:
            s.tube([(x+.046*cos(a),-.066,-.07+.022*sin(a)) for a in np.linspace(0,2*pi,32)],.003,1)
    # Each border carries its own sculpted emblem and relief rhythm.
    for centre in [-.375,-.125,.125,.375]:
        if id==2:
            for k in [-1,0,1]:s.box((centre+k*.033,-.064,-.065),(.013,.013,.048-abs(k)*.012),3,.004)
        elif id==5:
            s.tube([(centre+.029*cos(a),-.075,-.068+.029*sin(a)) for a in np.linspace(0,2*pi,32)],.005,1)
            s.bead((centre,-.071,-.068),(.020,.008,.020),2,16)
            for a in np.linspace(0,2*pi,8,endpoint=False):s.bead((centre+.039*cos(a),-.071,-.068+.039*sin(a)),(.003,.004,.003),1,8)
        elif id==7:
            s.tube([(centre+(.029+.003*cos(a*16))*cos(a),-.074,-.068+(.029+.003*cos(a*16))*sin(a)) for a in np.linspace(0,2*pi,128)],.005,1)
            for a in np.linspace(0,2*pi,6,endpoint=False):s.tube([(centre,-.075,-.068),(centre+.029*cos(a),-.075,-.068+.029*sin(a))],.003,1)
        elif id==8:
            for j in range(3):
                s.tube([(centre+(.042-j*.009)*u,-.075,-.10+j*.024+.014*u*u) for u in np.linspace(-1,1,22)],.0045,1)
        elif id==9:
            s.tube([(centre-.04,-.068,-.13),(centre-.022,-.073,-.09),(centre+.01,-.073,-.10),(centre+.04,-.068,-.035)],.009,2)
            s.tube([(centre-.04,-.078,-.13),(centre-.022,-.079,-.09),(centre+.01,-.079,-.10),(centre+.04,-.078,-.035)],.003,3)
        elif id==4:
            for sign in [-1,1]:s.tube([(centre+.05*u,-.073,-.066+sign*.018*sin(pi*u*2)) for u in np.linspace(-1,1,32)],.005,0)
        elif id==3:
            for j in range(7):
                a=(j-3)*.2;s.tube([(centre+.060*sin(a)*u,-.075,-.125+.062*cos(a)*u) for u in np.linspace(0,1,16)],.0035,1)
        elif id==101:
            for sign in [-1,1]:
                for j in range(3):
                    z=-.13+j*.025;s.tube([(centre,-.075,z),(centre+sign*.022,-.079,z+.018),(centre,-.075,z+.030)],.003,1)
        elif id==102:
            for sign in [-1,1]:
                pts=[(centre+sign*(.016+.032*(1-u)*cos(3*pi*u)),-.078,-.072+.033*(1-u)*sin(3*pi*u)) for u in np.linspace(0,1,44)]
                s.tube(pts,[.007-.004*float(u) for u in np.linspace(0,1,44)],1,7)
        elif id==103:
            for j in range(7):
                a=(j-3)*.22;s.tube([(centre,-.076,-.12),(centre+.065*sin(a),-.083,-.12+.066*cos(a)),(centre+.032*sin(a),-.076,-.097)],.003,1)
        elif id==105:
            for j in range(3):
                s.tube([(centre-.035+j*.035+.016*cos(a),-.077,-.07+.027*sin(a)) for a in np.linspace(0,2*pi,36)],.004,1)
        elif id==122:
            for row in range(3):
                for col in range(3):
                    x=centre+(col-1)*.023+(row%2)*.011;z=-.12+row*.025
                    s.tube([(x+.017*cos(a),-.077,z+.022*sin(a)) for a in np.linspace(0,pi,18)],.004,1)
    o=s.object(f'{id}-frame',mats);return o

def image(name,array):
    a=np.clip(array,0,1);h,w=a.shape[:2];img=bpy.data.images.new(name,w,h,alpha=True)
    if a.shape[2]==3:a=np.concatenate([a,np.ones((h,w,1))],axis=2)
    img.colorspace_settings.name='Non-Color'
    img.pixels.foreach_set(a.astype(np.float32).ravel());img.filepath_raw=str(OUT/(name+'.png'));img.file_format='PNG';img.save();bpy.data.images.remove(img)

def textures(t):
    # Deterministic high-resolution inlay, relief normals and satin roughness.
    id=t[0];n=512;y,x=np.mgrid[0:n,0:n]/n;X=x-.5;Y=y-.5;r=np.hypot(X,Y);a=np.arctan2(Y,X)
    rng=np.random.default_rng(id);grain=rng.random((n,n))-.5
    vein=np.sin(x*38+np.sin(y*19)*1.8+np.sin(x*8+y*13))
    wave=np.sin(x*30+np.sin(y*12)*3)
    fine=np.sin(x*570)*np.sin(y*570)
    border=(np.abs(np.maximum(abs(X),abs(Y))-.463)<.0025).astype(float)
    if id==1:orn=np.exp(-((X-.05*np.sin(y*24)-.12)**2)/.000035)
    elif id==2:orn=((np.mod(x*8,1)<.035)|(np.mod(y*8,1)<.035)).astype(float)*.45
    elif id==3:orn=np.exp(-(np.sin(y*28+np.sin(x*9)*2)**2)/.008)
    elif id==4:orn=np.exp(-(np.sin(x*35+sin(1)*np.sin(y*10))**2)/.012)
    elif id==5:orn=np.zeros_like(x)
    elif id==6:orn=np.exp(-(np.sin((x+y)*25)**2)/.015)*.65
    elif id==7:orn=np.exp(-((r-.31)**2)/.00002)+((abs(np.sin(a*24))<.09)&(r>.29)&(r<.33))
    elif id==8:orn=np.exp(-(np.sin(x*22)*np.sin(y*22))**2/.002)*.5
    elif id==9:orn=np.exp(-((np.sin(x*12+np.sin(y*10))+.2*np.sin(y*23))**2)/.002)
    elif id==10:orn=np.exp(-(np.sin(a*6)**2)/.001)*(r<.32)*(r>.05)
    elif id==101:orn=np.exp(-((r-(.20+.08*cos(0)*np.cos(a*8)))**2)/.00003)
    elif id==102:orn=np.exp(-(np.sin(y*35+np.cos(x*18))**2)/.005)
    elif id==103:orn=np.exp(-((r-(.24+.055*np.cos(a*12)))**2)/.000015)
    elif id==104:orn=np.exp(-(np.sin(x*18)*np.sin(y*18))**2/.001)*.7
    elif id==105:orn=np.exp(-(np.sin(y*26+np.sin(x*26)*1.4)**2)/.006)
    elif id==121:orn=sum(np.exp(-((np.hypot(X*np.cos(k)+Y*np.sin(k),(Y*np.cos(k)-X*np.sin(k))*2.1)-.32)**2)/.000012) for k in [0,pi/3,2*pi/3])
    else:orn=np.exp(-(np.sin(y*38+np.sin(x*30)*1.4)**2)/.012)
    orn=np.clip(orn,0,1)*(.25 if id<100 else .42)+border*.60
    height=grain*.025+vein*.015+orn*.25
    dy,dx=np.gradient(height);normal=np.stack([-dx*3,-dy*3,np.ones_like(x)],axis=-1);normal/=np.linalg.norm(normal,axis=2)[...,None];image(f'{id}-normal',normal*.5+.5)
    rough=.30 if id in [1,3,5,8,10,105] else .44
    rr=np.clip(rough+grain*.07+orn*.1,.08,.85);image(f'{id}-rough',np.stack([rr]*3,axis=-1))
    for side,base in [('light',t[2]),('dark',t[3])]:
        # Board light/dark values remain clearly separated, with restrained motif contrast.
        rgb=np.array([int(base[i:i+2],16)/255 for i in (0,2,4)])
        accent=np.array([int(t[4][i:i+2],16)/255 for i in (0,2,4)])
        arr=rgb[None,None,:]*(1+grain[...,None]*.025+vein[...,None]*.015)
        arr=arr*(1-orn[...,None]*.24)+accent[None,None,:]*orn[...,None]*.24
        image(f'{id}-{side}',arr)

def stage(t,objects):
    # Photograph the actual shipping mesh, using the same physical materials.
    for obj in list(bpy.data.objects):
        if obj not in objects:bpy.data.objects.remove(obj,do_unlink=True)
    for i,o in enumerate(objects):o.location=((i-2.5)*.72,0,0)
    mats=materials(t)
    ground=bpy.data.materials.new('Studio');ground.diffuse_color=(.045,.061,.079,1);ground.use_nodes=True;ground.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(.045,.061,.079,1);ground.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value=.33
    bpy.ops.mesh.primitive_plane_add(size=200);bpy.context.object.data.materials.append(ground);bpy.context.object.location.z=-.012;bpy.context.object.name='Studio floor'
    for name,location,energy,size in [('Key',(-3,-4,6),650,5),('Rim',(2,2,4),800,3),('Softbox',(4,-1,3),400,4)]:
        data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.shape='DISK';data.size=size;o=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(o);o.location=location;o.rotation_euler=(Vector((0,0,.4))-o.location).to_track_quat('-Z','Y').to_euler()
    data=bpy.data.cameras.new('Portrait camera');cam=bpy.data.objects.new('Portrait camera',data);bpy.context.collection.objects.link(cam);cam.location=(2.3,-6,3.1);cam.rotation_euler=(Vector((0,0,.44))-cam.location).to_track_quat('-Z','Y').to_euler();data.type='ORTHO';data.ortho_scale=5.1;bpy.context.scene.camera=cam
    scene=bpy.context.scene;scene.render.engine='CYCLES';scene.cycles.samples=40;scene.cycles.use_denoising=True;scene.world.color=(.22,.22,.22)
    scene.render.resolution_x=1800;scene.render.resolution_y=1000;scene.render.resolution_percentage=100
    scene.view_settings.view_transform='AgX';scene.render.image_settings.file_format='PNG';scene.render.filepath=str(ART/f'{t[0]}-portrait.png')
    bpy.ops.wm.save_as_mainfile(filepath=str(ART/f'{t[0]}-atelier.blend'),compress=True)
    bpy.ops.render.render(write_still=True)
    # Second photograph: both armies on the matching finished playing surface.
    bpy.data.objects['Studio floor'].location.z=-.245
    black=materials(t,False)
    for i,o in enumerate(objects):
        o.location.y=-.62
        other=o.copy();other.data=o.data.copy();bpy.context.collection.objects.link(other);other.location.y=.62
        for j,m in enumerate(black):other.data.materials[j]=m
    tilem=[]
    for side in ['light','dark']:
        m=bpy.data.materials.new(side+' inlaid board');m.use_nodes=True
        nodes=m.node_tree.nodes;p=nodes.get('Principled BSDF');p.inputs['Roughness'].default_value=.32;p.inputs['Coat Weight'].default_value=.2
        tex=nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(OUT/f'{t[0]}-{side}.png'));tex.image.pack();m.node_tree.links.new(tex.outputs['Color'],p.inputs['Base Color'])
        tilem.append(m)
    for row in range(4):
        for col in range(8):
            bpy.ops.mesh.primitive_plane_add(size=.62,location=((col-3.5)*.62,(row-1.5)*.62,-.007));bpy.context.object.data.materials.append(tilem[(row+col)%2])
    base=Sculpt();base.box((0,0,-.115),(5.16,2.68,.21),0,.065);base.object('Bound board platform',black)
    frame=board_module(t,black)
    for side in range(4):
        count=8 if side%2==0 else 4
        for i in range(count):
            o=frame.copy();o.data=frame.data;bpy.context.collection.objects.link(o);o.scale=(.62,.62,.62);v=(i-(count-1)/2)*.62
            o.location=[(v,-1.31,0),(2.55,v,0),(-v,1.31,0),(-2.55,-v,0)][side];o.rotation_euler.z=side*pi/2
    bpy.data.objects.remove(frame,do_unlink=True)
    cam.location=(2.8,-6,4.3);cam.rotation_euler=(Vector((0,0,.22))-cam.location).to_track_quat('-Z','Y').to_euler();data.ortho_scale=6.2
    scene.render.resolution_y=1200;scene.render.filepath=str(ART/f'{t[0]}-board.png')
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type=='VIEW_3D':
                area.spaces.active.region_3d.view_perspective='CAMERA';area.spaces.active.shading.type='MATERIAL'
    bpy.ops.wm.save_as_mainfile(filepath=str(ART/f'{t[0]}-atelier.blend'),compress=True)
    bpy.ops.render.render(write_still=True)

def main():
    args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [];ids=[int(v) for v in args if v.isdigit()]
    allstats=[]
    for t in THEMES:
        if ids and t[0] not in ids:continue
        start=time.time();bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
        mats=materials(t);models=[];stats=[]
        for kind in 'PNBRQK':
            o=sculpt_piece(t,kind,mats);models.append(o)
            hi=export(o,OUT/f'{t[0]}-{kind}.ccmesh');lo=export(o,OUT/f'{t[0]}-{kind}-lod.ccmesh',.25 if t[0]>120 else (.34 if t[0]>100 else .43))
            stats.append({'theme':t[0],'piece':kind,'high':hi,'low':lo})
            print('EXPORTED',t[0],kind,hi['triangles'],flush=True)
        frame=board_module(t,mats);export(frame,OUT/f'{t[0]}-frame.ccmesh');bpy.data.objects.remove(frame,do_unlink=True)
        textures(t)
        (OUT/f'{t[0]}-manifest.json').write_text(json.dumps(stats,indent=2));allstats.extend(stats)
        stage(t,models);print('COMPLETE',t[0],round(time.time()-start,2),flush=True)
    (ART/'last-build.json').write_text(json.dumps(allstats,indent=2))
if __name__=='__main__':main()
