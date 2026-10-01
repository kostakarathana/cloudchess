"""Authored cumulus density and smooth outward normals for the live Metal volume.
R holds density; GBA hold encoded world-space normals. No baked lighting/image.
"""
from pathlib import Path
import json
import numpy as np
from scipy.ndimage import gaussian_filter
rng=np.random.default_rng(70421)
W,H,D=128,64,256
z,y,x=np.meshgrid(np.arange(D)/D*26-13,np.arange(H)/H*7-2,np.arange(W)/W*14-7,indexing='ij')
field=np.full((D,H,W),-8,np.float32)
# x, z, altitude, width, depth, height. Large connected foundations support
# unequal taller crests, with deliberate valleys and a quiet board-sized center.
forms=[
 # A lower, quieter deck is visible through gaps between the tall perimeter
 # banks. It catches the platform shadow several units below the playing surface.
 (0,-2.0,-1.25,3.3,4.8,.70),(1.1,4.0,-1.20,3.4,3.3,.85),
 (-2.3,-6.0,-1.1,3.1,3.2,.80),
 (-5.1,-9.4,-.25,3.6,4.0,1.15),(-4.9,-4.9,-.4,2.8,3.8,1.0),
 (-5.9,-.6,-.7,2.5,3.6,.8),(-5.5,3.7,-.35,2.8,3.8,1.0),
 (-4.1,8.5,-.2,3.7,3.5,1.05),(-.5,11.3,-.55,4.2,2.7,.85),
 (5.0,-10.0,-.25,3.4,3.4,1.1),(5.9,-5.3,-.45,2.7,3.7,1.0),
 (6.1,-.7,-.7,2.4,3.5,.8),(5.0,4.5,-.4,3.3,3.4,1.0),
 (3.7,8.5,-.2,3.7,3.2,1.1),
 # Upper-left cluster: one hero billow, offset shoulders, flowing trailing edge.
 (-3.4,-7.6,.85,2.0,2.3,1.65),(-4.9,-9.9,.55,1.8,2.0,1.45),
 (-2.4,-9.6,.30,1.35,1.5,1.1),(-4.35,-5.0,.6,1.5,1.8,1.4),
 (-5.2,-2.8,.05,1.25,1.9,1.05),
 # Upper right is deliberately smaller and lower.
 (4.05,-9.3,.7,1.9,1.9,1.5),(5.05,-6.6,.5,1.45,1.85,1.3),
 (2.7,-10.9,.1,1.4,1.55,1.05),
 # Foreground banks step toward the opening, then sweep offscreen.
 (-4.6,4.65,.35,1.65,2.0,1.3),(-3.3,7.2,.8,2.05,2.1,1.6),
 (-1.35,9.6,.4,1.7,1.6,1.25),(-4.7,9.9,.3,1.65,1.7,1.3),
 (3.65,5.7,.95,2.05,2.3,1.65),(5.2,3.5,.35,1.55,1.95,1.25),
 (2.0,8.65,.55,1.8,1.8,1.35),(4.4,10.55,.5,1.85,1.7,1.35)]
for px,pz,py,rx,rz,ry in forms:
 dx=(x-px+7)%14-7;dz=(z-pz+13)%26-13
 d=(1-np.sqrt((dx/rx)**2+((y-py)/ry)**2+(dz/rz)**2))*min(rx,ry,rz)
 k=.28;h=np.maximum(k-np.abs(field-d),0)/k
 field=np.maximum(field,d)+h*h*k*.25
noise=gaussian_filter(rng.random((D,H,W)).astype(np.float32),1.5,mode='wrap')
noise=(noise-noise.mean())/noise.std()
broad=gaussian_filter(noise,4,mode='wrap');broad/=broad.std()
field += np.clip(noise,-2,2)*.018+np.clip(broad,-2,2)*.070
q=np.clip((field+.065)/.19,0,1);density=q*q*(3-2*q)
# Filter the contour before differentiating: light describes soft broad lobes,
# not high-frequency bumps. Spacing matches the volume's world dimensions.
smooth=gaussian_filter(field,1.2,mode=('wrap','nearest','wrap'))
gz,gy,gx=np.gradient(smooth,26/D,7/H,14/W)
normal=-np.stack([gx,gy,gz],axis=-1)
normal/=np.maximum(np.linalg.norm(normal,axis=-1,keepdims=True),1e-6)
raw=np.empty((D,H,W,4),np.uint8)
raw[...,0]=np.uint8(np.clip(density,0,1)*255)
raw[...,1:]=np.uint8(np.clip(normal*.5+.5,0,1)*255)
out=Path(__file__).resolve().parents[1]/'CloudChess/Assets.xcassets/CloudDensity.dataset';out.mkdir(exist_ok=True)
(out/'density.bin').write_bytes(raw.tobytes())
(out/'Contents.json').write_text(json.dumps({'data':[{'filename':'density.bin','idiom':'universal'}],'info':{'author':'xcode','version':1}}))
assert raw.shape==(256,64,128,4) and raw[...,0].min()==0 and raw[...,0].max()==255
assert np.isfinite(normal).all()
print('Generated 30 layered cumulus forms, RGBA8 density + contour normals, 8 MiB')
