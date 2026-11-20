extension ShaderSource {
    static let defringe = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct DefringeParams {
        uint firstRow, scratchFirstRow;
        float purpleRadius, purpleLow, purpleHigh, greenRadius, greenLow, greenHigh;
        float chromaLow, chromaHigh, y0, donorColour, frontier, feather;
    };
    float3 yk(float3 rgb) { return float3(dot(rgb, float3(0.2627,0.6780,0.0593)), rgb.r-rgb.g, rgb.b-rgb.g); }
    float hue_score(float2 e, float low, float high, constant float* table, float feather) {
        float angle = atan2(0.629564*e.x-0.533624*e.y, 0.343440*e.x+0.183699*e.y) * (180.0/M_PI_F);
        if (angle < 0) angle += 360;
        float x = angle/5;
        int j = min(int(x),71);
        float K = mix(table[21+j], table[21+(j+1)%72], x-j);
        float a = angle;
        if (a < (table[0]+table[20])*0.5-180) a += 360;
        int i = 0;
        for (int n=1; n<20; ++n) if (a >= table[n]) i=n;
        float t = i*5 + 5*(a-table[i])/(table[i+1]-table[i]);
        return K * clamp((t-low+feather)/feather,0.0,1.0) * clamp((high+feather-t)/feather,0.0,1.0);
    }
    float weight(float3 p, float low, float high, constant float* table, constant DefringeParams& P) {
        float floor=smoothstep(P.chromaLow,P.chromaHigh,length(p.yz)/(p.x+P.y0));
        return floor==0 ? 0 : floor*hue_score(p.yz,low,high,table,P.feather);
    }
    // Share each donor's hue calculation across the horizontal stencil.
    kernel void defringe_horizontal(texture2d<float,access::read> scene [[texture(0)]],
                                    texture2d_array<float,access::write> sums [[texture(1)]],
                                    constant DefringeParams& P [[buffer(0)]], constant float* tables [[buffer(1)]],
                                    uint3 gid [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
        bool purple=gid.z==0 && P.purpleRadius>0;
        float r=purple ? P.purpleRadius : P.greenRadius;
        float low=purple ? P.purpleLow : P.greenLow, high=purple ? P.purpleHigh : P.greenHigh;
        constant float* table=tables+(purple ? 0 : 93);
        int halo=int(ceil(r)), start=int(gid.x)-int(tid)-halo;
        uint y=gid.y+P.scratchFirstRow;
        threadgroup float3 donors[168];
        for (int i=int(tid); i<128+2*halo; i+=128) {
            int x=start+i;
            float3 donor=float3(0);
            if (x>=0 && x<int(scene.get_width())) {
                float3 p=yk(scene.read(uint2(x,y)).rgb);
                float d=1-weight(p,low,high,table,P);
                donor=float3(d,p.x>0 ? d*p.yz/p.x : float2(0));
            }
            donors[i]=donor;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (gid.x>=scene.get_width()) return;
        float3 sum=float3(0);
        for (int dx=-halo; dx<=halo; ++dx)
            sum+=max(0.0,r+1-abs(float(dx)))*donors[int(tid)+halo+dx];
        sums.write(float4(sum,0),gid.xy,gid.z);
    }
    kernel void defringe_repair(texture2d<half,access::read> scene [[texture(0)]],
                                texture2d_array<float,access::read> sums [[texture(1)]],
                                texture2d<half,access::write> out [[texture(2)]],
                                constant DefringeParams& P [[buffer(0)]], constant float* tables [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint2 pos=uint2(gid.x,gid.y+P.firstRow);
        if (pos.x>=scene.get_width() || pos.y>=scene.get_height()) return;
        half4 original=scene.read(pos);
        float3 p=yk(float3(original.rgb));
        if (p.x<=0) { out.write(original,pos); return; }
        float hp=P.purpleRadius>0 ? weight(p,P.purpleLow,P.purpleHigh,tables,P) : 0;
        float hg=P.greenRadius>0 ? weight(p,P.greenLow,P.greenHigh,tables+93,P) : 0;
        float total=max(1.0,hp+hg);
        float2 change=float2(0);
        bool repaired=false;
        for (uint band=0; band<sums.get_array_size(); ++band) {
            bool purple=band==0 && P.purpleRadius>0;
            float r=purple ? P.purpleRadius : P.greenRadius;
            float h=purple ? hp : hg;
            if (h==0) continue;
            int halo=int(ceil(r));
            float3 sum=float3(0);
            for (int dy=-halo; dy<=halo; ++dy) {
                int y=int(pos.y)+dy;
                if (y>=0 && y<int(scene.get_height()))
                    sum+=max(0.0,r+1-abs(float(dy)))*sums.read(uint2(pos.x,y-int(P.scratchFirstRow)),band).xyz;
            }
            if (sum.x==0) continue;
            float m=1-pow(P.frontier,sum.x/((r+1)*(r+1)));
            float2 donor=P.donorColour*(sum.yz/sum.x)*p.x;
            change+=(h/total)*m*(donor-p.yz);
            repaired=true;
        }
        if (!repaired) { out.write(original,pos); return; }
        float2 k=p.yz+change;
        float G=p.x-0.2627*k.x-0.0593*k.y;
        out.write(half4(half3(G+k.x,G,G+k.y),original.a),pos);
    }
    """#
}
