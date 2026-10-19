#include <metal_stdlib>
using namespace metal;
struct CityUniforms {
    float4x4 viewProjection;
    float4x4 lightViewProjection;
    float4 eye, clockAudio, bandsBeat, instruments, rhythm, structure, layout, phasesPresence, colorViewport, presentation;
};
struct CityVertex { float4 position; float4 normal; float4 surface; };
struct CityVarying {
    float4 position [[position]];
    float3 world, normal;
    float2 uv;
    float4 lightPosition;
    uint band [[flat]];
    uint material [[flat]];
    float bodyHeight [[flat]];
};
float cityHash(float n) { return fract(sin(n*127.1+17.7)*43758.5453); }
constant uint2 cityBuildingCells[40] = {
    uint2(0,0), uint2(1,0), uint2(0,1), uint2(2,0), uint2(1,1), uint2(0,2), uint2(3,0), uint2(2,1),
    uint2(1,2), uint2(0,3), uint2(4,0), uint2(3,1), uint2(2,2), uint2(1,3), uint2(0,4), uint2(4,1),
    uint2(3,2), uint2(2,3), uint2(1,4), uint2(0,5), uint2(4,2), uint2(3,3), uint2(2,4), uint2(1,5),
    uint2(0,6), uint2(4,3), uint2(3,4), uint2(2,5), uint2(1,6), uint2(0,7), uint2(4,4), uint2(3,5),
    uint2(2,6), uint2(1,7), uint2(4,5), uint2(3,6), uint2(2,7), uint2(4,6), uint2(3,7), uint2(4,7)
};
constant uint cityCellBands[40] = {
    0, 1, 3, 6, 10,
    2, 4, 7, 11, 15,
    5, 8, 12, 16, 20,
    9, 13, 17, 21, 25,
    14, 18, 22, 26, 30,
    19, 23, 27, 31, 34,
    24, 28, 32, 35, 37,
    29, 33, 36, 38, 39
};
uint2 cityGridForBand(uint band) { return cityBuildingCells[band]; }
uint cityBandAtGrid(uint2 grid) { return cityCellBands[grid.y*5+grid.x]; }
float2 cityBlockSeparation(constant CityUniforms &u) {
    // FFT indexing stays independent of the physical floor proportions.
    // The long axis gives the left-to-foreground edge room, as in the reference.
    return float2(1.80,1.30)+(u.layout.x-0.5)*float2(0.035,0.025);
}
float2 cityBuildingScale(uint band, constant CityUniforms &u) {
    float frequency=float(band)/39;
    return float2((1.00-frequency*0.48)*(0.70+cityHash(float(band)+11)*0.32)*(0.96+u.layout.y*0.08),
                  (1.02-frequency*0.44)*(0.72+cityHash(float(band)+29)*0.26));
}
float2 cityBuildingCenter(uint band, constant CityUniforms &u) {
    float2 separation=cityBlockSeparation(u);
    float2 grid=float2(cityGridForBand(band))-float2(2.0,3.5);
    float2 jitter=float2(cityHash(float(band)+2),cityHash(float(band)+93))-0.5;
    return grid*separation+jitter*0.10;
}
float cityBuildingHeight(uint band, float spectral, constant CityUniforms &u) {
    float frequency=float(band)/39;
    // One consecutive group of FFT bins owns each building; silent bands receive no invented animation.
    float height=0.075+pow(clamp(spectral,0.0,1.0),1.45)*3.6
                     *(1.10-frequency*0.63)*(0.67+cityHash(float(band)+41)*0.42);
    return height*(1+u.bandsBeat.w*0.025+u.instruments.z*(1-frequency)*0.025);
}
float3 cityBandColor(float frequency, constant CityUniforms &u) {
    float analysisTint=u.phasesPresence.w*(u.colorViewport.x-0.5)*0.09;
    float tint=clamp(frequency+analysisTint+u.colorViewport.y*0.025,0.0,1.0);
    // Larger low-frequency towers need a shorter cyan range. The continuous
    // cyan/azure/blue/violet gradient balances visible area without flat bands.
    float3 cyan=float3(0.005,0.50,1.0), azure=float3(0.010,0.20,1.0);
    float3 blue=float3(0.035,0.050,1.0), violet=float3(0.55,0.025,1.0);
    if (tint<0.14) return mix(cyan,azure,smoothstep(0.0,0.14,tint));
    if (tint<0.34) return mix(azure,blue,smoothstep(0.14,0.34,tint));
    return mix(blue,violet,smoothstep(0.34,1.0,tint));
}
float2 cityRoadDistances(float2 p, constant CityUniforms &u) {
    float2 separation=cityBlockSeparation(u);
    return abs(fract(p/separation+float2(0.0,0.5))-0.5)*separation;
}
float cityGoldActivity(constant CityUniforms &u) {
    // RMS is live audio. Peak includes an analysed musical accent, so it must
    // not keep an illuminated arc alive through digital silence.
    float audio=sqrt(clamp(u.clockAudio.y,0.0,1.0))*2*smoothstep(0.001,0.012,u.clockAudio.y);
    return audio*(0.55+sqrt(max(0.0,u.bandsBeat.w))*0.55+sqrt(max(0.0,u.rhythm.z))*0.35
            +u.instruments.y*0.15)*clamp(u.phasesPresence.w,0.0,1.0);
}
float3 cityGoldPoint(float phase, constant CityUniforms &u, const device float4 *route) {
    float t=fract(phase), sample=t*512;
    uint index=min(511u,uint(sample));
    float2 p=mix(route[index].xz,route[index+1].xz,fract(sample))*cityBlockSeparation(u);
    // Music phase changes both the position of the head and the height of the
    // whole travelling bundle. A complete bar joins without a temporal seam.
    float y=0.55+0.30*sin((t*2-fract(u.phasesPresence.y))*6.283185-0.4);
    return float3(p.x,y,p.y);
}
float cityGoldTail(float behind) {
    return exp(-behind*1.7)*(1-smoothstep(0.82,1.0,behind));
}
// This is soft illumination from the elevated body, never its sharp core.
float cityGoldSpill(float2 p, constant CityUniforms &u, const device float4 *route) {
    float activity=cityGoldActivity(u);
    if (activity<0.001) return 0;
    float spill=0;
    for (uint index=0;index<24;++index) {
        float behind=float(index)/23;
        float3 source=cityGoldPoint(fract(u.phasesPresence.y)-0.55*behind,u,route);
        float2 delta=p-source.xz;
        float spread=0.14+source.y*0.22;
        spill+=exp(-dot(delta,delta)/spread)*cityGoldTail(behind)/(0.7+source.y*source.y);
    }
    return spill*activity*0.24;
}
float cityGoldSurfaceSpill(float3 world, float3 normal, constant CityUniforms &u, const device float4 *route) {
    float activity=cityGoldActivity(u);
    if (activity<0.001 || world.y>1.3) return 0;
    float light=0;
    for (uint index=0;index<16;++index) {
        float behind=float(index)/15;
        float3 source=cityGoldPoint(fract(u.phasesPresence.y)-0.55*behind,u,route);
        float3 delta=world-source;
        float facing=max(0.08,dot(normal,normalize(source-world)));
        delta.y*=1.7;
        light+=exp(-dot(delta,delta)/0.30)*cityGoldTail(behind)*facing;
    }
    return light*activity*0.35*(1-smoothstep(0.85,1.3,world.y));
}
struct CityGoldVarying { float4 position [[position]]; float behind, profile; uint glow [[flat]]; };
CityGoldVarying cityGoldTube(CityVertex v, uint instance, constant CityUniforms &u,
                            const device float4 *route, bool reflected) {
    uint strand=instance%7;
    bool glow=instance>=7;
    float phase=fract(u.phasesPresence.y)-v.position.x*0.55-(float(strand)-3)*0.0025;
    float3 center=cityGoldPoint(phase,u,route);
    float3 tangent=normalize(cityGoldPoint(phase+0.0003,u,route)-cityGoldPoint(phase-0.0003,u,route));
    float3 side=normalize(cross(float3(0,1,0),tangent)), up=normalize(cross(tangent,side));
    center+=side*(float(strand)-3)*0.037+up*sin(float(strand)*1.7)*0.018;
    float radius=glow?0.055:(0.006+sqrt(max(0.0,u.bandsBeat.w))*0.002);
    radius*=0.45+0.55*cityGoldTail(v.position.x);
    float3 normal=side*cos(v.position.y)+up*sin(v.position.y);
    float3 world=center+normal*radius;
    if (reflected) { world.y=-world.y; normal.y=-normal.y; }
    float profile=max(0.0,dot(normal,normalize(u.eye.xyz-world)));
    return {u.viewProjection*float4(world,1),v.position.x,profile,uint(glow)};
}
vertex CityGoldVarying cityGoldVertex(uint id [[vertex_id]], uint strand [[instance_id]],
                                     constant CityUniforms &u [[buffer(0)]],
                                     const device CityVertex *vertices [[buffer(2)]], const device float4 *route [[buffer(3)]]) {
    return cityGoldTube(vertices[id],strand,u,route,false);
}
vertex CityGoldVarying cityGoldReflectionVertex(uint id [[vertex_id]], uint strand [[instance_id]],
                                     constant CityUniforms &u [[buffer(0)]],
                                     const device CityVertex *vertices [[buffer(2)]], const device float4 *route [[buffer(3)]]) {
    return cityGoldTube(vertices[id],strand,u,route,true);
}
fragment float4 cityGoldFragment(CityGoldVarying in [[stage_in]], constant CityUniforms &u [[buffer(0)]]) {
    float light=cityGoldTail(in.behind)*cityGoldActivity(u)*clamp(u.phasesPresence.z,0.0,1.0);
    if (light<0.001) discard_fragment();
    float3 color=in.glow!=0 ? float3(0.48,0.19,0.018)*pow(in.profile,2.0) : float3(7.5,4.0,0.80);
    // Alpha records the actual tube geometry, including its outer glow profile.
    // RGB remains additive; alpha uses source-over coverage in the pipeline.
    float coverage=in.glow!=0 ? clamp(in.profile*in.profile*light,0.0,1.0) : 1.0;
    return float4(color*light,coverage);
}
CityVarying cityBuilding(CityVertex v, uint band, constant CityUniforms &u, float spectral) {
    float height=cityBuildingHeight(band,spectral,u);
    float2 buildingScale=cityBuildingScale(band,u);
    float width=buildingScale.x,depth=buildingScale.y;
    float2 center=cityBuildingCenter(band,u);
    float y=v.surface.w<0.5?0.13+v.position.y*height:
            (v.surface.w>1.5?0.13+height+v.position.y:v.position.y);
    float3 world=float3(center.x+v.position.x*width,y,center.y+v.position.z*depth);
    float3 scaling=float3(width,v.surface.w<0.5?height:1.0,depth);
    CityVarying out;
    out.world=world; out.position=u.viewProjection*float4(world,1);
    out.normal=normalize(v.normal.xyz/scaling); out.uv=v.surface.xy;
    // Vocal fill uses body height, not the separate UV of every bevel or roof part.
    out.uv.y=v.surface.w<0.5?v.position.y:1.0;
    out.band=band; out.material=uint(v.surface.z);
    out.bodyHeight=height;
    out.lightPosition=u.lightViewProjection*float4(world,1);
    return out;
}
vertex CityVarying cityBuildingVertex(uint id [[vertex_id]], uint band [[instance_id]],
                                     constant CityUniforms &u [[buffer(0)]], const device float *spectrum [[buffer(1)]],
                                     const device CityVertex *vertices [[buffer(2)]]) {
    return cityBuilding(vertices[id],band,u,spectrum[band]);
}
vertex CityVarying cityReflectionVertex(uint id [[vertex_id]], uint band [[instance_id]],
                                       constant CityUniforms &u [[buffer(0)]], const device float *spectrum [[buffer(1)]],
                                       const device CityVertex *vertices [[buffer(2)]]) {
    CityVarying out=cityBuilding(vertices[id],band,u,spectrum[band]);
    out.position=u.viewProjection*float4(out.world.x,-out.world.y,out.world.z,1);
    return out;
}
vertex CityVarying cityCrystalVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                     constant CityUniforms &u [[buffer(0)]], const device float *spectrum [[buffer(1)]],
                                     const device CityVertex *vertices [[buffer(2)]], const device uint *order [[buffer(4)]]) {
    uint band=order[instance];
    return cityBuilding(vertices[id],band,u,spectrum[band]);
}
vertex CityVarying cityCrystalReflectionVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                     constant CityUniforms &u [[buffer(0)]], const device float *spectrum [[buffer(1)]],
                                     const device CityVertex *vertices [[buffer(2)]], const device uint *order [[buffer(4)]]) {
    uint band=order[instance];
    CityVarying out=cityBuilding(vertices[id],band,u,spectrum[band]);
    out.position=u.viewProjection*float4(out.world.x,-out.world.y,out.world.z,1);
    return out;
}
vertex float4 cityShadowVertex(uint id [[vertex_id]], uint band [[instance_id]],
                              constant CityUniforms &u [[buffer(0)]], const device float *spectrum [[buffer(1)]],
                              const device CityVertex *vertices [[buffer(2)]]) {
    return cityBuilding(vertices[id],band,u,spectrum[band]).lightPosition;
}
vertex CityVarying cityBaseVertex(uint id [[vertex_id]], constant CityUniforms &u [[buffer(0)]],
                                const device CityVertex *vertices [[buffer(2)]]) {
    CityVertex v=vertices[id];
    CityVarying out;
    out.world=v.position.xyz; out.normal=v.normal.xyz; out.uv=v.surface.xy;
    out.position=u.viewProjection*v.position; out.lightPosition=u.lightViewProjection*v.position;
    out.band=0; out.material=uint(v.surface.z);
    out.bodyHeight=0;
    return out;
}
float cityShadow(float4 lightPosition, depth2d<float> shadow) {
    constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge,compare_func::less_equal);
    float3 p=lightPosition.xyz/lightPosition.w;
    float2 uv=p.xy*float2(0.5,-0.5)+0.5;
    if (any(uv<0.0)||any(uv>1.0)||p.z>1.0) return 1;
    float2 pixel=1.0/float2(shadow.get_width(),shadow.get_height());
    float visibility=0;
    for (int y=-1;y<=1;y+=2) for (int x=-1;x<=1;x+=2)
        visibility+=shadow.sample_compare(s,uv+float2(x,y)*pixel*0.9,p.z-0.0015)*0.25;
    return visibility;
}
// The studio texture is an authored LDR environment, sampled in linear light.
float3 cityEnvironment(float3 direction, float roughness, texture2d<float> environment) {
    constexpr sampler studio(coord::normalized, filter::linear, mip_filter::linear,
                             s_address::repeat, t_address::clamp_to_edge);
    float3 r=normalize(direction);
    float2 uv=float2(atan2(r.z,r.x)/6.283185+0.5,acos(clamp(r.y,-1.0,1.0))/3.141593);
    return environment.sample(studio,uv,level(roughness*5.0)).rgb;
}
float3 cityFresnel(float3 f0, float cosine) { return f0+(1-f0)*pow(1-clamp(cosine,0.0,1.0),5.0); }
float3 cityMaterial(float3 base, float3 world, float3 normal, float roughness, float metalness,
                    float3 tint, float visibility, constant CityUniforms &u, texture2d<float> environment) {
    float3 n=normalize(normal),v=normalize(u.eye.xyz-world),l=normalize(float3(-8,14,-9)-world),h=normalize(v+l);
    float nv=max(0.001,dot(n,v)),nl=max(0.0,dot(n,l)),nh=max(0.0,dot(n,h));
    float alpha=roughness*roughness,a2=alpha*alpha;
    float denom=nh*nh*(a2-1)+1;
    float distribution=a2/(3.141593*denom*denom+0.00001);
    float k=(roughness+1)*(roughness+1)/8;
    float geometry=(nv/(nv*(1-k)+k))*(nl/(nl*(1-k)+k));
    float3 f0=mix(float3(0.055),mix(base,tint*0.18,0.24),metalness);
    float3 f=cityFresnel(f0,max(0.0,dot(v,h)));
    float3 specular=distribution*geometry*f/max(0.001,4*nv*max(0.001,nl));
    float3 diffuse=(1-f)*base*(1-metalness)/3.141593;
    float3 result=(diffuse+specular)*nl*float3(2.2,2.4,2.8)*visibility+base*0.05;
    float3 reflected=cityEnvironment(reflect(-v,n),roughness,environment);
    result+=reflected*cityFresnel(f0,nv)*(0.7+metalness*1.2);
    return result;
}
float cityFinStrength(float lateral, uint band, float height) {
    float fin=floor(lateral*8+4);
    return (0.58+cityHash(float(band)*31)*0.45)
           *(0.48+cityHash(float(band)*11+fin*7)*0.72)
           *(0.15+0.85*smoothstep(0.14,0.29,abs(lateral)))
           *(0.60+0.40*exp(-height*0.60));
}
float3 cityBuildingColor(CityVarying in, constant CityUniforms &u, float visibility, texture2d<float> environment,
                         const device float4 *route) {
    float frequency=float(in.band)/39;
    float3 tint=cityBandColor(frequency,u);
    float analysis=clamp(u.phasesPresence.w,0.0,1.0);
    float vocal=clamp(u.instruments.x,0.0,1.0)*analysis;
    float other=clamp(u.instruments.w,0.0,1.0)*analysis;
    // Vocal activity fills the middle towers' vertical lights from their bases.
    // The fill height follows activity, while the actual tower height stays FFT-driven.
    float vocalFocus=smoothstep(0.16,0.35,frequency)*(1-smoothstep(0.70,0.85,frequency));
    float vocalLevel=0.08+vocal*0.84;
    float vocalFill=vocal*vocalFocus*(1-smoothstep(vocalLevel-0.06,vocalLevel+0.06,in.uv.y));
    vocalFill*=1-smoothstep(0.1,0.5,abs(in.normal.y));
    float light=0.95+u.clockAudio.w*0.30+u.layout.w*0.15+u.rhythm.w*0.12;
    light+=u.structure.w*0.15+u.bandsBeat.w*float(in.band)/39*0.22;
    light*=0.94+u.structure.x*0.06+sin(u.structure.y*6.283185)*0.025;
    float3 color;
    if (in.material==5 || in.material==8) {
        float facing=in.normal.y>0.5?1.0:(0.035+0.965*max(0.0,in.normal.z));
        // The narrow edges of side fins must not inherit the hot front light.
        if (in.material==8) facing=0.01+0.08*max(0.0,-in.normal.x);
        float2 local=(in.world.xz-cityBuildingCenter(in.band,u))/cityBuildingScale(in.band,u);
        float lateral=in.material==8?local.y:local.x;
        if (in.normal.y<0.5) lateral=sign(lateral)*(abs(lateral)<0.205?(in.material==8?0.11:0.12):(in.material==8?0.28:0.29));
        float rail=cityFinStrength(lateral,in.band,in.world.y);
        if (in.normal.y>0.5) rail/=0.15+0.85*smoothstep(0.14,0.29,abs(lateral));
        float shimmer=0.985+sin(u.clockAudio.x*(0.3+u.rhythm.y*0.4)+float(in.band)*0.47)*0.015;
        bool roof=in.normal.y>0.5;
        color=(tint*(roof?2.0:0.65)+float3(roof?1.2:0.85))*light*rail*facing*shimmer;
        // Vocal energy strengthens the colored glass light without turning all
        // four fins into equally white stripes or overriding their own strength.
        color+=tint*2.4*vocalFill*facing*rail;
        // A separate roof accent belongs to the other-instrument activity.
        if (in.normal.y>0.5) color+=tint*other*3.0;
        color+=float3(1.3,0.8,0.32)*exp(-in.world.y*3.0);
    } else if (in.material==6) {
        color=float3(2.8,1.6,0.6)*(0.75+u.instruments.y*0.25);
    } else if (in.material==2) {
        float3 normal=normalize(in.normal);
        bool side=abs(in.normal.x)>abs(in.normal.z);
        float3 view=normalize(u.eye.xyz-in.world);
        float3 crystalTint=mix(float3(1.0),pow(max(tint,float3(0.0)),float3(0.80)),0.96);
        float3 transmittedRay=refract(-view,normal,1.0/1.46);
        float2 scale=cityBuildingScale(in.band,u);
        float2 center=cityBuildingCenter(in.band,u);
        float height=max(0.075,in.bodyHeight);
        float3 local=float3((in.world.x-center.x)/scale.x,
                            clamp((in.world.y-0.13)/height,0.0,1.0),
                            (in.world.z-center.y)/scale.y);
        float3 ray=transmittedRay/float3(scale.x,height,scale.y);
        float3 boundary=mix(float3(-0.39,0,-0.41),float3(0.39,1,0.41),step(float3(0),ray));
        float3 distances=abs(boundary-local)/max(abs(ray),float3(0.0001));
        float opticalDepth=max(0.001,min(distances.x,min(distances.y,distances.z)));
        float3 exitPoint=local+ray*opticalDepth;
        // Absorption depends on the distance through the solid crystal, rather
        // than a black painted face with repeated luminous stripes.
        float3 absorption=-log(max(crystalTint,float3(0.001)))*0.85;
        float3 transmission=exp(-absorption*opticalDepth);
        float fresnel=0.035+0.965*pow(1-clamp(dot(view,normal),0.0,1.0),5.0);
        float3 refractedStudio=cityEnvironment(transmittedRay,0.18,environment);
        float3 reflectedStudio=cityEnvironment(reflect(-view,normal),0.12,environment);
        float backLateral=side?exitPoint.z:exitPoint.x;
        float halfFace=side?0.41:0.39;
        float innerEdge=exp(-pow((abs(backLateral)-halfFace)/0.055,2.0));
        float innerPlane=0.55+0.45*smoothstep(-halfFace,halfFace,backLateral);
        float facing=side?0.72:1.0;
        float3 innerLight=crystalTint*(0.48+innerPlane*0.30+innerEdge*0.48)
                         *(0.88+exitPoint.y*0.12)*facing*light;
        color=(innerLight+refractedStudio*1.5)*transmission*(1-fresnel);
        // The pale surface reflection is separate from the colored interior.
        color+=reflectedStudio*(0.22+fresnel*1.4);
        float faceLateral=side?local.z:local.x;
        float edge=pow(clamp(abs(faceLateral)/halfFace,0.0,1.0),18.0);
        color+=crystalTint*edge*(0.22+fresnel*0.65)*light;
        color+=crystalTint*vocalFill*0.22*transmission;
    } else if (in.material==3) {
        float3 crystalTint=mix(float3(1),pow(max(tint,float3(0)),float3(0.80)),0.96);
        color=cityMaterial(crystalTint*0.08,in.world,in.normal,0.08,0.0,tint,visibility,u,environment);
        color+=crystalTint*0.09;
    } else {
        float3 base=in.material==4?float3(0.028,0.038,0.053):float3(0.006,0.009,0.016);
        color=cityMaterial(base,in.world,in.normal,in.material==4?0.25:0.26,0.82,tint,visibility,u,environment);
        if (in.material==4) {
            color=cityMaterial(float3(0.42,0.50,0.62),in.world,in.normal,0.12,0.10,tint,visibility,u,environment);
            color+=float3(0.28,0.32,0.40);
        }
    }
    float2 roads=cityRoadDistances(in.world.xz,u);
    float roadHalo=exp(-pow(min(roads.x,roads.y)/0.26,2.0));
    float floorLight=0.025*roadHalo;
    float movingLight=cityGoldSurfaceSpill(in.world,normalize(in.normal),u,route);
    return color+float3(1.3,0.58,0.12)*floorLight*exp(-in.world.y*4.5)
                +float3(1.8,0.72,0.075)*movingLight;
}
fragment float4 cityBuildingFragment(CityVarying in [[stage_in]], constant CityUniforms &u [[buffer(0)]],
                                     depth2d<float> shadow [[texture(1)]], texture2d<float> environment [[texture(2)]],
                                     const device float4 *route [[buffer(3)]]) {
    float presence=clamp(u.phasesPresence.z,0.0,1.0);
    if (presence<0.001 || in.material==2) discard_fragment();
    return float4(cityBuildingColor(in,u,cityShadow(in.lightPosition,shadow),environment,route)*presence,1);
}
fragment float4 cityReflectionFragment(CityVarying in [[stage_in]], constant CityUniforms &u [[buffer(0)]],
                                       texture2d<float> environment [[texture(2)]], const device float4 *route [[buffer(3)]]) {
    if (u.phasesPresence.z<0.001 || in.material==2) discard_fragment();
    return float4(cityBuildingColor(in,u,0.8,environment,route)*u.phasesPresence.z,1);
}
fragment float4 cityCrystalFragment(CityVarying in [[stage_in]], constant CityUniforms &u [[buffer(0)]],
                                       texture2d<float> environment [[texture(2)]], const device float4 *route [[buffer(3)]]) {
    float presence=clamp(u.phasesPresence.z,0.0,1.0);
    if (presence<0.001 || in.material!=2) discard_fragment();
    float3 view=normalize(u.eye.xyz-in.world);
    if (dot(view,normalize(in.normal))<=0.0) discard_fragment();
    float edge=pow(1-clamp(dot(view,normalize(in.normal)),0.0,1.0),5.0);
    float opacity=(0.34+edge*0.22)*presence;
    return float4(cityBuildingColor(in,u,0.9,environment,route)*opacity,opacity);
}
fragment float4 cityBaseFragment(CityVarying in [[stage_in]], constant CityUniforms &u [[buffer(0)]],
                                 const device float *spectrum [[buffer(1)]], texture2d<float> reflection [[texture(0)]],
                                 depth2d<float> shadow [[texture(1)]], texture2d<float> environment [[texture(2)]],
                                 texture2d<float> roughReflection [[texture(3)]], const device float4 *route [[buffer(3)]]) {
    float presence=clamp(u.phasesPresence.z,0.0,1.0);
    if (presence<0.001) discard_fragment();
    float3 color; float2 p=in.world.xz;
    if (in.material==7) {
        color=float3(0.0006,0.0008,0.0012);
        // Soft light reflected by the studio floor around the raised platform.
        for (uint edge=0;edge<13;++edge) {
            uint band=cityBandAtGrid(edge<5 ? uint2(edge,7) : uint2(0,edge-5));
            float2 source=cityBuildingCenter(band,u)+(edge<5 ? float2(0,0.55) : float2(-0.55,0));
            float2 delta=p-source;
            float2 spread=edge<5 ? float2(0.48,2.4) : float2(2.4,0.48);
            float footprint=exp(-delta.x*delta.x/spread.x-delta.y*delta.y/spread.y);
            color+=cityBandColor(float(band)/39,u)*footprint*(0.025+spectrum[band]*0.13);
        }
        float grain=0.94+0.06*cityHash(floor(p.x*120)+floor(p.y*120)*31);
        color*=grain;
    } else if (in.normal.y>0.9) {
        float visibility=cityShadow(in.lightPosition,shadow);
        color=cityMaterial(float3(0.003,0.004,0.007),in.world,in.normal,0.20,0.65,
                           float3(0.03,0.07,0.14),visibility,u,environment)*0.22;
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 uv=in.position.xy/u.colorViewport.zw;
        float nv=max(0.0,dot(normalize(u.eye.xyz-in.world),float3(0,1,0)));
        float fresnel=0.10+0.90*pow(1-nv,5.0);
        float2 separation=cityBlockSeparation(u);
        float2 grid=cityRoadDistances(p,u);
        float moving=cityGoldSpill(p,u,route);
        int2 origin=int2(floor(p/separation+float2(2.0,3.5)));
        float nearest=100;
        for (int z=0;z<2;++z) for (int x=0;x<2;++x) {
            int2 block=origin+int2(x,z);
            if (any(block<0)||block.x>4||block.y>7) continue;
            uint band=cityBandAtGrid(uint2(block));
            float2 delta=p-cityBuildingCenter(band,u);
            float d=dot(delta,delta);
            nearest=min(nearest,d);
            color*=1-exp(-d/0.16)*0.12;
            float3 tint=cityBandColor(float(band)/39,u);
            float energy=0.015+spectrum[band]*0.07;
            color+=tint*exp(-d/0.35)*energy;
            // Curb lamps follow the actual building dimensions. Their warm spill
            // stays local, so the black floor and the mirror remain visible.
            float2 curb=abs(delta)-float2(0.51,0.53)*cityBuildingScale(band,u);
            float lamp=exp(-dot(curb,curb)/0.035);
            float warmth=0.8+u.instruments.y*clamp(u.phasesPresence.w,0.0,1.0)*0.3+moving*0.15;
            color+=float3(0.26,0.105,0.018)*lamp*warmth;
        }
        float blurMix=0.30+0.55*smoothstep(0.08,1.4,nearest);
        float3 mirror=mix(reflection.sample(s,uv).rgb,roughReflection.sample(s,uv).rgb,blurMix);
        color+=mirror*fresnel*1.8;
        float roadDistance=min(grid.x,grid.y);
        float aa=max(0.001,fwidth(roadDistance));
        float junction=exp(-dot(grid,grid)/(0.12*0.12));
        color+=float3(0.80,0.34,0.055)*moving;
        color+=float3(1.6,0.68,0.10)*junction*moving*0.18;
        // Blue-violet street light travels in musical bar phase. With no activity
        // or no analysis it contributes nothing, including any residual smoothed input.
        float other=clamp(u.instruments.w,0.0,1.0)*clamp(u.phasesPresence.w,0.0,1.0);
        float trail=pow(0.5+0.5*cos((p.x+p.y)*0.85-u.phasesPresence.y*6.283185),6.0);
        float street=1-smoothstep(0.004,0.014+aa,abs(roadDistance-0.024));
        color+=float3(0.12,0.08,0.85)*street*other*trail;
        float edge=max(abs(p.x)/4.6,abs(p.y)/5.3);
        color+=cityBandColor(clamp((p.x+p.y+9.9)/19.8,0.0,1.0),u)*(1-smoothstep(0.003,0.012,abs(edge-0.991)))*0.10;
    } else {
        color=cityMaterial(float3(0.002,0.003,0.006),in.world,in.normal,0.24,0.72,
                           float3(0.03,0.08,0.16),1,u,environment)*0.32;
    }
    // Material 7 is the 60x60 studio surround, not the raised city foundation.
    // Keep the foundation and buildings solid while the surround reveals glass.
    float alpha=in.material==7 ? u.presentation.x : 1.0;
    return float4(color*presence*alpha,alpha);
}
struct CityFullscreen { float4 position [[position]]; float2 uv; };
vertex CityFullscreen cityFullscreenVertex(uint id [[vertex_id]]) {
    float2 p=float2(id==2?3:-1,id==1?3:-1);
    return {float4(p,0,1),p*float2(0.5,-0.5)+0.5};
}
fragment float4 cityBrightFragment(CityFullscreen in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 pixel=1.0/float2(scene.get_width(),scene.get_height()); float3 color=0;
    for (int y=-1;y<=1;y+=2) for (int x=-1;x<=1;x+=2) {
        float3 c=scene.sample(s,in.uv+float2(x,y)*pixel).rgb;
        color+=c*smoothstep(0.65,1.40,max(c.r,max(c.g,c.b)))*0.25;
    }
    return float4(color,1);
}
fragment float4 cityCompositeFragment(CityFullscreen in [[stage_in]], constant CityUniforms &u [[buffer(0)]],
                                      texture2d<float> scene [[texture(0)]], texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float4 sceneColor=scene.sample(s,in.uv);
    float3 color=sceneColor.rgb+bloom.sample(s,in.uv).rgb*(0.23+u.clockAudio.w*0.09);
    float alpha=clamp(sceneColor.a,0.0,1.0);
    // The MSAA scene carries premultiplied linear RGB and geometry coverage.
    // Tone mapping needs straight RGB to avoid darkening silhouette edges twice.
    if (u.presentation.x<1.0) color=alpha>0.0 ? color/alpha : float3(0);
    color*=1-dot(in.uv-0.5,in.uv-0.5)*0.20;
    float3 mapped=(color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14);
    mapped=clamp(mapped,0.0,1.0);
    if (u.presentation.x>=1.0) return float4(mapped,1);
    // bgra8Unorm_srgb encodes the shader output on store. Core Animation needs
    // the stored sRGB values premultiplied, so encode, multiply, then decode.
    float3 encoded=select(1.055*pow(mapped,float3(1.0/2.4))-0.055,
                          mapped*12.92,mapped<=0.0031308);
    encoded*=alpha;
    float3 premultiplied=select(pow((encoded+0.055)/1.055,float3(2.4)),
                                encoded/12.92,encoded<=0.04045);
    return float4(premultiplied,alpha);
}
