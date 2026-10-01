import Foundation

enum CloudVolumeShader {
    // True world-space rays share the board's camera. The cloud volume is below
    // the platform, with sunlight occlusion and an altitude-dependent soft shadow.
    static let source="""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
        float4 screen;float4 touch;float4 wind;
        float4 eye;float4 forward;float4 up;float4 sun;float4 board;float4 shadow;float4 light;
    };
    struct VertexOut {float4 position [[position]];float2 uv;};
    vertex VertexOut cloudVertex(uint id [[vertex_id]]) {
        float2 p=float2((id<<1)&2,id&2);
        VertexOut o;o.position=float4(p*2.0-1.0,0,1);o.uv=float2(p.x,1.0-p.y);return o;
    }
    constexpr sampler volumeSampler(coord::normalized,address::repeat,filter::linear);
    float4 cloudSample(float3 p,texture3d<float> tex,float time) {
        // The authored volume's local y range [-2,5] sits 5 units below the board.
        float3 q=p+float3(0,5.2,0);
        q.x += sin(time*.026+q.z*.12)*.34+sin(time*.041+q.y*.4)*.09;
        q.z += sin(time*.019+q.x*.15)*.26;
        q.y += sin(time*.032+q.z*.22+q.x*.18)*.055;
        float3 coordinate=float3((q.x+7.0)/14.0,(q.y+2.0)/7.0,(q.z+13.0)/26.0);
        coordinate.y=clamp(coordinate.y,0.5/64.0,1.0-0.5/64.0);
        return tex.sample(volumeSampler,coordinate);
    }
    float density(float3 p,texture3d<float> tex,float time) {return cloudSample(p,tex,time).r;}
    float platformShadow(float3 p,float3 sun,float2 extent) {
        // Project the actual platform footprint toward the light. The penumbra
        // grows with separation, grounding the platform without a dark sticker.
        float3 atBoard=p+sun*(-p.y/sun.y);
        float softness=.28+max(0.0,-p.y)*.19;
        float2 outside=abs(atBoard.xz)-extent;
        float distance=max(outside.x,outside.y);
        return 1.0-smoothstep(-softness,softness,distance);
    }
    fragment float4 cloudFragment(VertexOut in [[stage_in]],constant Uniforms &u [[buffer(0)]],texture3d<float> tex [[texture(0)]]) {
        float2 uv=in.uv;
        float aspect=u.screen.x/u.screen.y;
        float2 ndc=float2(uv.x*2.0-1.0,1.0-uv.y*2.0);
        float3 ray=normalize(u.forward.xyz+float3(1,0,0)*ndc.x*u.eye.w*aspect+u.up.xyz*ndc.y*u.eye.w);
        float3 origin=u.eye.xyz;
        float3 sun=u.sun.xyz;
        float2 delta=(uv-u.touch.xy)*float2(1.0,1.0/aspect);
        float influence=exp(-dot(delta,delta)/.024);
        float entry=(-.8-origin.y)/ray.y;
        float exit=(-7.15-origin.y)/ray.y;
        float step=(exit-entry)/64.0;
        float jitter=fract(sin(dot(floor(in.position.xy),float2(12.9898,78.233)))*43758.5453);
        float t=entry+jitter*step;
        float3 color=float3(0);float trans=1;
        for(int i=0;i<64;i++,t+=step) {
            float3 world=origin+ray*t;
            float3 p=world;
            p.xz -= u.wind.xy*influence*1.2;
            p.xz += float2(-delta.y,delta.x)*influence*length(u.wind.xy)*.65;
            p.y += u.wind.z*influence;
            float4 sample=cloudSample(p,tex,u.screen.z);
            float d=sample.r;
            if(d>.005) {
                float optical=0;
                optical += density(p+sun*.25,tex,u.screen.z)*.25;
                optical += density(p+sun*.65,tex,u.screen.z)*.40;
                optical += density(p+sun*1.3,tex,u.screen.z)*.65;
                optical += density(p+sun*2.5,tex,u.screen.z)*1.2;
                float light=exp(-optical*1.05);
                float3 normal=normalize(sample.gba*2.0-1.0);
                float wrapped=clamp(dot(normal,sun)*.55+.48,0.0,1.0);
                float sculpted=mix(.43,1.0,wrapped);
                float3 shade=u.shadow.xyz+u.light.xyz*light*sculpted;
                shade += (1.0-exp(-d*1.6))*float3(.025,.028,.035);
                shade *= .92+.08*smoothstep(-6.0,-2.5,p.y);
                shade *= 1.0-platformShadow(world-float3(0,u.board.z,u.board.w),sun,u.board.xy)*.17;
                // Far clouds softly merge into the blue atmosphere.
                float haze=smoothstep(28.0,46.0,t)*.22;
                shade=mix(shade,float3(.65,.77,.88),haze);
                float alpha=1.0-exp(-d*step*3.4);
                color += trans*alpha*shade;trans *= 1.0-alpha;
                if(trans<.012)break;
            }
        }
        float3 sky=u.shadow.w==0 ? mix(float3(.53,.69,.84),float3(.69,.80,.89),uv.y) : u.shadow.xyz*.65+u.light.xyz*.18;
        // Cheap atmosphere accents after the volume pass; no additional rays.
        if(u.shadow.w==1) {
            float phase=fmod(u.screen.z,13.0);
            float flash=exp(-pow((phase-9.0)*3.2,2.0))*.14;
            color+=flash*float3(.6,.75,1.0);
            float2 rain=uv*float2(105,45)+float2(u.screen.z*.4,u.screen.z*10);
            float cell=fract(sin(floor(rain.x)*71.13)*437.19);
            float streak=smoothstep(.975,1.0,fract(rain.x+uv.y*.45))*smoothstep(.7,1.0,fract(rain.y+cell));
            color+=streak*.035;
        }
        if(u.shadow.w==11 || u.shadow.w==13) {
            float ribbon=exp(-pow((uv.y-.23-.09*sin(uv.x*5+u.screen.z*.045))*17,2.0));
            color+=ribbon*float3(.025,.06,.08);
        }
        color += trans*sky;
        // Sparse world-specific atmosphere in the existing pass, with no new
        // particle systems, lights or raymarch samples. Time freezes with Motion off.
        if(u.shadow.w==2 || u.shadow.w==13) {
            float2 starGrid=uv*float2(31,55);
            float2 id=floor(starGrid),cell=fract(starGrid)-.5;
            float seed=fract(sin(dot(id,float2(71.3,19.7)))*43758.3);
            float star=exp(-dot(cell,cell)*650.0)*metal::step(.88,seed);
            color+=star*(.025+.018*sin(u.screen.z*.45+seed*21.0))*float3(.7,.82,1.0);
        }
        if(u.shadow.w==3) {
            float a=sin(uv.x*19.0+sin(uv.y*13.0+u.screen.z*.10)*1.5);
            float b=sin(uv.y*24.0+sin(uv.x*11.0-u.screen.z*.08));
            color+=pow(max(0.0,a*b),12.0)*float3(.01,.022,.025);
        }
        if(u.shadow.w==4 || u.shadow.w==9 || u.shadow.w==10 || u.shadow.w==12) {
            float2 grid=uv*float2(12,22)+float2(sin(u.screen.z*.13)*.14,u.screen.z*(u.shadow.w==10 ? -.12:.09));
            float2 id=floor(grid),cell=fract(grid)-.5;
            float seed=fract(sin(dot(id,float2(21.7,39.1)))*12837.1);
            float mote=exp(-dot(cell,cell)*(u.shadow.w==10 ? 650.0:280.0))*metal::step(.85,seed);
            float3 tint=u.shadow.w==9 ? float3(.11,.032,.01):(u.shadow.w==12 ? float3(.02,.08,.065):(u.shadow.w==10 ? float3(.075,.085,.09):float3(.08,.065,.025)));
            color+=mote*tint*(.7+.3*sin(seed*24.0+u.screen.z*.4));
        }
        float sunshine=exp(-dot(uv-float2(.08,.12),uv-float2(.08,.12))/.4);
        color=mix(color,color*float3(1.025,1.008,.985),sunshine*.5);
        return float4(pow(clamp(color,0.0,1.0),float3(1.0/2.2)),1);
    }
    """
}
