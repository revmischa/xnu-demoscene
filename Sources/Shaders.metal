#include <metal_stdlib>
using namespace metal;

// Mirrors `Uniforms` in Renderer.swift. Field order and alignment must match.
struct Uniforms {
    float4 cpu[4];
    float2 resolution;
    float time, beat, sceneTime, sceneProgress;
    float kick, snare, hat, bass, lead, leadNote;
    float memPressure, loadAvg, procCount, uptime;
    float transition, textAlpha, scrollFrac;
    int scene, cols, rows, ncpu, scrollRow;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y);
    return o;
}

// ---------------------------------------------------------------- helpers

constant float PI = 3.14159265;

inline float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; return fract(p * (p + p)); }
inline float hash21(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
inline float2 hash22(float2 p) { float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }

inline float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3 - 2 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + 1), f.x), f.y);
}
inline float fbm(float2 p) {
    float v = 0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return v;
}
inline float2 rot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
inline float3 palette(float t, float3 a, float3 b, float3 c, float3 d) { return a + b * cos(2 * PI * (c * t + d)); }
inline float3 pal(float t) { return palette(t, float3(0.5), float3(0.5), float3(1, 1, 1), float3(0.0, 0.33, 0.67)); }
inline float3 palCold(float t) { return palette(t, float3(0.5), float3(0.5), float3(1, 1, 0.5), float3(0.8, 0.9, 0.3)); }

inline float sdBox(float2 p, float2 b) { float2 d = abs(p) - b; return length(max(d, 0)) + min(max(d.x, d.y), 0.0); }
inline float sdBox3(float3 p, float3 b) { float3 d = abs(p) - b; return length(max(d, 0)) + min(max(d.x, max(d.y, d.z)), 0.0); }
inline float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1 - h); }
inline float cpuLoad(constant Uniforms& u, int i) { return u.cpu[(i >> 2) & 3][i & 3]; }

// ---------------------------------------------------------------- scene 0: boot

float3 sceneBoot(float2 p, float2 uv, constant Uniforms& u) {
    float t = u.time;
    float3 col = 0;
    for (int i = 0; i < 3; i++) {
        float s = 6.0 + i * 5.0;
        float2 q = p * s + float2(t * 0.03 * (i + 1), t * 0.01);
        float2 id = floor(q), f = fract(q) - 0.5;
        float h = hash21(id + i * 7.3);
        if (h > 0.93) {
            float2 o = (hash22(id + 3.1) - 0.5) * 0.7;
            float d = length(f - o);
            float tw = 0.6 + 0.4 * sin(t * 2.5 + h * 60);
            col += (0.5 / (i + 1)) * tw * smoothstep(0.06, 0.0, d) * float3(0.7, 0.85, 1);
        }
    }
    // perspective grid floor rising out of the dark as boot proceeds
    float horizon = -0.05;
    if (p.y < horizon) {
        float z = 1.0 / (horizon - p.y);
        float2 g = float2(p.x * z, z + t * 1.5);
        float lines = smoothstep(0.46, 0.5, abs(fract(g.x * 1.5) - 0.5)) + smoothstep(0.46, 0.5, abs(fract(g.y * 0.5) - 0.5));
        float fade = exp(-z * 0.08) * u.sceneProgress;
        col += lines * fade * float3(0.1, 0.5, 0.4) * (0.5 + 0.5 * u.kick);
    }
    // radial pulse
    col += float3(0.05, 0.12, 0.1) * exp(-length(p) * 2.5) * (0.3 + u.kick) * u.sceneProgress;
    // a scan sweep
    float sweep = fract(t * 0.15);
    col += float3(0.15, 0.3, 0.25) * smoothstep(0.03, 0.0, abs(uv.y - sweep)) * 0.4;
    return col;
}

// ---------------------------------------------------------------- scene 1: mach ports (metaballs)

constant int NTASK = 7;

inline float3 taskPos(int i, float t) {
    float fi = float(i);
    return float3(sin(t * 0.5 + fi * 2.1) * 1.7, cos(t * 0.37 + fi * 1.3) * 0.9, sin(t * 0.43 + fi * 0.7 + 1.0) * 1.7);
}

inline float mapPorts(float3 p, constant Uniforms& u, thread float& id) {
    float d = 1e9; id = 0;
    for (int i = 0; i < NTASK; i++) {
        float r = 0.32 + 0.18 * cpuLoad(u, i) + 0.06 * u.kick;
        float di = length(p - taskPos(i, u.time)) - r;
        float nd = smin(d, di, 0.6);
        if (di < d) id = float(i);
        d = nd;
    }
    return d;
}

inline float3 normPorts(float3 p, constant Uniforms& u) {
    float id; float2 e = float2(0.002, 0);
    return normalize(float3(mapPorts(p + e.xyy, u, id) - mapPorts(p - e.xyy, u, id),
                            mapPorts(p + e.yxy, u, id) - mapPorts(p - e.yxy, u, id),
                            mapPorts(p + e.yyx, u, id) - mapPorts(p - e.yyx, u, id)));
}

float3 scenePorts(float2 p, constant Uniforms& u) {
    float t = u.time;
    float3 ro = float3(sin(t * 0.2) * 6.5, 1.6 + sin(t * 0.13) * 0.8, cos(t * 0.2) * 6.5);
    float3 fwd = normalize(-ro), right = normalize(cross(fwd, float3(0, 1, 0))), up = cross(right, fwd);
    float focal = 1.6;
    float3 rd = normalize(fwd * focal + right * p.x + up * p.y);

    float3 col = float3(0.01, 0.015, 0.03) + float3(0.02, 0.04, 0.08) * pow(max(0.0, rd.y), 0.5);
    float2 sp = rd.xz / (abs(rd.y) + 0.2) * 3.0;
    float st = hash21(floor(sp * 14.0 + t * 0.1));
    col += float3(0.15, 0.25, 0.4) * smoothstep(0.992, 1.0, st) * (0.5 + 0.5 * sin(t * 3 + st * 100));
    float td = 0, id = 0; bool hit = false;
    for (int i = 0; i < 90; i++) {
        float3 pos = ro + rd * td;
        float d = mapPorts(pos, u, id);
        if (d < 0.002) { hit = true; break; }
        td += d * 0.9;
        if (td > 20) break;
    }
    if (hit) {
        float3 pos = ro + rd * td;
        float3 n = normPorts(pos, u);
        float3 l1 = normalize(float3(0.6, 1, 0.4)), l2 = normalize(float3(-0.7, -0.2, -0.5));
        float3 base = pal(id * 0.13 + 0.4) * 0.6 + 0.2;
        float dif = max(dot(n, l1), 0.0), dif2 = max(dot(n, l2), 0.0) * 0.4;
        float fres = pow(1 - max(dot(n, -rd), 0.0), 3.0);
        float spec = pow(max(dot(reflect(rd, n), l1), 0.0), 40.0);
        col = base * (dif + dif2 + 0.1) + fres * float3(0.3, 0.7, 1.0) * 1.2 + spec * 0.8;
        col *= exp(-td * 0.06);
    }
    // messages: glowing packets travelling between tasks, projected to screen
    for (int i = 0; i < NTASK; i++) {
        for (int k = 1; k <= 2; k++) {
            int j = (i + k * 2 + 1) % NTASK;
            float3 a = taskPos(i, t), b = taskPos(j, t);
            float3 da = a - ro, db = b - ro;
            float za = dot(da, fwd), zb = dot(db, fwd);
            if (za < 0.1 || zb < 0.1) continue;
            float2 sa = float2(dot(da, right), dot(da, up)) / za * focal;
            float2 sb = float2(dot(db, right), dot(db, up)) / zb * focal;
            float2 pa = p - sa, ba = sb - sa;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            float dl = length(pa - ba * h);
            col += float3(0.1, 0.3, 0.5) * smoothstep(0.004, 0.0, dl) * 0.25;
            float ph = fract(u.beat * 0.25 + float(i) * 0.17 + float(k) * 0.41);
            float3 m = mix(a, b, ph);
            float3 dm = m - ro; float zm = dot(dm, fwd);
            if (zm < 0.1) continue;
            float2 sm = float2(dot(dm, right), dot(dm, up)) / zm * focal;
            float dd = length(p - sm);
            col += float3(0.4, 0.8, 1.0) * (0.0004 / (dd * dd + 0.00002)) * (0.5 + 0.5 * u.hat) * 0.5;
        }
    }
    return col;
}

// ---------------------------------------------------------------- scene 2: plasma

float3 scenePlasma(float2 p, constant Uniforms& u) {
    float t = u.time * 0.7;
    float2 q = rot(p, sin(t * 0.1) * 0.4) * (3.0 + u.loadAvg * 2.0);
    float v = sin(q.x + t) + sin((q.y + t) * 1.3) + sin((q.x + q.y) * 0.8 + t * 0.7);
    float2 c = q + float2(sin(t * 0.5), cos(t * 0.3)) * 2;
    v += sin(length(c) * 1.5 - t * 2.0);
    v += sin(length(q - float2(cos(t * 0.4), sin(t * 0.6)) * 3) * 2.0 + t);
    float3 col = pal(v * 0.18 + t * 0.05);
    float bands = pow(0.5 + 0.5 * sin(v * 2.5 + t * 2.0), 3.0);
    col = col * col * (0.15 + 0.85 * bands);
    col *= 0.45 + 0.45 * u.bass;
    col += float3(0.0, 0.25, 0.1) * smoothstep(0.95, 1.0, sin(v * 3 + t * 4)) * u.kick;
    return col * 0.7;
}

// ---------------------------------------------------------------- scene 3: tunnel

float3 sceneTunnel(float2 p, constant Uniforms& u) {
    float t = u.time;
    float2 q = p + float2(sin(t * 0.7), cos(t * 0.9)) * 0.25;
    q = rot(q, u.beat * 0.08 + u.snare * 0.15);
    float shape = 0.5 + 0.5 * sin(t * 0.3);
    float rc = length(q);
    float rs = pow(pow(abs(q.x), 6.0) + pow(abs(q.y), 6.0), 1.0 / 6.0);
    float r = mix(rc, rs, shape);
    float a = atan2(q.y, q.x);
    float speed = 2.5 + u.loadAvg * 3.0;
    float2 tuv = float2(a / PI * 8.0 + t * 0.3, 2.0 / r + t * speed);
    float2 cell = fract(tuv) - 0.5;
    float grid = smoothstep(0.42, 0.5, max(abs(cell.x), abs(cell.y)));
    float checker = step(0.5, fract(tuv.x * 0.5)) == step(0.5, fract(tuv.y * 0.5)) ? 1.0 : 0.3;
    float n = fbm(float2(cos(a) * 2.0 + t * 0.1, sin(a) * 2.0 + tuv.y * 0.3));   // periodic in a: no seam
    float3 base = palCold(tuv.y * 0.02 + a / PI + t * 0.1);   // a/PI: period-2 blue channel stays seamless
    float3 col = base * base * checker * (0.25 + 0.6 * n) * 0.35;
    col += base * grid * (0.25 + 0.35 * u.kick);
    // packets: bright rings flying inward on hats
    float ring = smoothstep(0.12, 0.0, abs(fract(tuv.y * 0.0625) - fract(u.beat * 0.5)));
    col += float3(1.0, 0.9, 0.6) * ring * u.hat;
    col *= smoothstep(0.0, 0.3, r);
    col *= (1 - exp(-r * 3.5));
    return col;
}

// ---------------------------------------------------------------- scene 4: panic

float3 scenePanic(float2 p, float2 uv, constant Uniforms& u) {
    float3 col = float3(0.004, 0.004, 0.006);
    float flick = 0.9 + 0.1 * hash11(floor(u.time * 60));
    col *= flick;
    // the moment of panic: a white flash decaying from scene start
    col += float3(0.6, 0.6, 0.7) * exp(-u.sceneTime * 6.0);
    return col;
}

// ---------------------------------------------------------------- scene 5: XNU finale

inline float sdU(float2 p) {
    float bars = min(sdBox(p - float2(-0.42, 0.3), float2(0.13, 0.6)), sdBox(p - float2(0.42, 0.3), float2(0.13, 0.6)));
    float2 c = p - float2(0, -0.3);
    float arc = abs(length(c) - 0.42) - 0.13;
    arc = max(arc, c.y);
    return min(bars, arc);
}
inline float sdN(float2 p) {
    float bars = min(sdBox(p - float2(-0.45, 0), float2(0.13, 0.9)), sdBox(p - float2(0.45, 0), float2(0.13, 0.9)));
    float diag = sdBox(rot(p, -0.47), float2(0.13, 0.95));
    return min(bars, diag);
}
inline float sdX(float2 p) {
    return min(sdBox(rot(p, 0.6), float2(0.13, 1.0)), sdBox(rot(p, -0.6), float2(0.13, 1.0)));
}

inline float letters2D(float2 p) {
    float dx = sdX(p - float2(-2.0, 0));
    float dn = sdN(p);
    float du = sdU(p - float2(2.0, 0));
    return min(dx, min(dn, du));
}

inline float mapXNU(float3 p, constant Uniforms& u) {
    float s = 1.0 + 0.04 * u.kick;
    float3 q = p / s;
    q.xz = rot(q.xz, sin(u.time * 0.4) * 0.3);
    float d2 = letters2D(q.xy);
    float2 w = float2(d2, abs(q.z) - 0.3);
    float d = min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - 0.03;
    return d * s;
}

inline float3 normXNU(float3 p, constant Uniforms& u) {
    float2 e = float2(0.002, 0);
    return normalize(float3(mapXNU(p + e.xyy, u) - mapXNU(p - e.xyy, u),
                            mapXNU(p + e.yxy, u) - mapXNU(p - e.yxy, u),
                            mapXNU(p + e.yyx, u) - mapXNU(p - e.yyx, u)));
}

inline float3 copperSky(float3 rd, constant Uniforms& u) {
    float3 col = float3(0.01, 0.0, 0.02);
    float y = rd.y * 3.0;
    for (int i = 0; i < 7; i++) {
        float fi = float(i);
        float yc = sin(u.time * 0.9 + fi * 0.9) * 1.2 + 0.2;
        float d = abs(y - yc);
        float3 c = pal(fi * 0.14 + u.beat * 0.02);
        col += c * exp(-d * d * 60.0) * (0.5 + 0.5 * u.kick) * 0.9;
    }
    col += float3(0.05, 0.02, 0.1) * max(0.0, -rd.y);
    return col;
}

float3 shadeXNU(float3 pos, float3 rd, float3 n, constant Uniforms& u) {
    float3 l1 = normalize(float3(0.5, 0.8, -0.6)), l2 = normalize(float3(-0.6, 0.3, 0.7));
    float3 refl = reflect(rd, n);
    float3 env = copperSky(refl, u) * 0.8;
    float fres = pow(1 - max(dot(n, -rd), 0.0), 4.0);
    float dif = max(dot(n, l1), 0.0) * 0.8 + max(dot(n, l2), 0.0) * 0.5;
    float spec = pow(max(dot(refl, l1), 0.0), 60.0) + pow(max(dot(refl, l2), 0.0), 30.0) * 0.5;
    float3 base = float3(0.75, 0.78, 0.85);
    float3 col = base * dif * 0.3 + env * (0.4 + 0.6 * fres) + spec * 1.2;
    // beat-synced emissive edge glow
    float edge = smoothstep(0.6, 1.0, fres);
    col += pal(u.beat * 0.1) * edge * u.lead * 1.5;
    return col;
}

float3 sceneXNU(float2 p, constant Uniforms& u) {
    float t = u.time;
    float th = sin(t * 0.25) * 0.55;   // swing across the front only; from behind the letters read mirrored
    float3 ro = float3(sin(th) * 6.5, 1.0 + sin(t * 0.17) * 1.2, cos(th) * 6.5);
    float3 ta = float3(0, 0, 0);
    float3 fwd = normalize(ta - ro), right = normalize(cross(fwd, float3(0, 1, 0))), up = cross(right, fwd);
    float3 rd = normalize(fwd * 1.7 + right * p.x + up * p.y);
    float floorY = -1.4;

    float3 col = copperSky(rd, u);
    float td = 0; bool hit = false;
    for (int i = 0; i < 100; i++) {
        float3 pos = ro + rd * td;
        float d = mapXNU(pos, u);
        if (d < 0.002) { hit = true; break; }
        td += d;
        if (td > 30) break;
    }
    float tFloor = rd.y < 0 ? (floorY - ro.y) / rd.y : 1e9;
    if (hit && td < tFloor) {
        float3 pos = ro + rd * td;
        col = shadeXNU(pos, rd, normXNU(pos, u), u);
    } else if (tFloor < 1e8) {
        float3 fp = ro + rd * tFloor;
        float2 g = fp.xz;
        float gl = smoothstep(0.45, 0.5, abs(fract(g.x) - 0.5)) + smoothstep(0.45, 0.5, abs(fract(g.y) - 0.5));
        float3 fcol = float3(0.02, 0.01, 0.04) + pal(u.beat * 0.05 + length(g) * 0.05) * gl * 0.5 * (0.4 + 0.6 * u.kick);
        // reflection of the letters in the floor
        float3 rr = reflect(rd, float3(0, 1, 0));
        float rt = 0; bool rhit = false;
        for (int i = 0; i < 60; i++) {
            float d = mapXNU(fp + rr * rt, u);
            if (d < 0.004) { rhit = true; break; }
            rt += d;
            if (rt > 20) break;
        }
        float3 rcol = copperSky(rr, u) * 0.3;
        if (rhit) { float3 rp = fp + rr * rt; rcol = shadeXNU(rp, rr, normXNU(rp, u), u); }
        float fres = pow(1 - max(dot(-rd, float3(0, 1, 0)), 0.0), 2.0);
        col = fcol + rcol * (0.25 + 0.5 * fres);
        col *= exp(-tFloor * 0.05);
    }
    return col;
}

// ---------------------------------------------------------------- scene 6: credits

float3 sceneCredits(float2 p, float2 uv, constant Uniforms& u) {
    float t = u.time;
    float3 col = sceneBoot(p, uv, u) * 0.6;
    float2 q = rot(p, t * 0.1) * (7.0 + 3.0 * sin(t * 0.2));
    q += float2(t * 0.6, t * 0.2);
    float ch = step(0.5, fract(q.x)) == step(0.5, fract(q.y)) ? 1.0 : 0.0;
    col += pal(t * 0.05 + length(p)) * ch * 0.035 * (1 - smoothstep(0.0, 1.2, length(p)));
    return col;
}

// ---------------------------------------------------------------- text overlay

float4 textOverlay(float2 uv, constant Uniforms& u, texture2d<float> atlas, texture2d<float> grid, sampler s) {
    float2 c = uv * float2(u.cols, u.rows);
    if (u.scene == 4) {
        // glitch: horizontal slice tearing that worsens as the panic progresses
        float g = u.sceneProgress * 0.6 + u.snare * 0.5 + u.kick * 0.3;
        float slice = floor(c.y) + floor(u.time * 24.0);
        float h = hash11(slice * 1.7);
        if (h > 0.9 - g * 0.3) c.x += (hash11(slice + 3.3) - 0.5) * 12.0 * g;
    }
    if (u.scrollRow >= 0) {
        float center = float(u.scrollRow) + 0.5;
        if (abs(c.y - center) < 3.5) {
            c.y -= sin(c.x * 0.18 + u.time * 2.8) * 2.2;
            c.x += u.scrollFrac;
            if (int(floor(c.y)) != u.scrollRow) return 0;
        }
    }
    int2 ij = int2(floor(c));
    if (ij.x < 0 || ij.y < 0 || ij.x >= u.cols || ij.y >= u.rows) return 0;
    float2 g = grid.read(uint2(ij)).rg;
    int code = int(g.r * 255.0 + 0.5);
    if (code < 33) return 0;
    int idx = code - 32;
    float2 f = fract(c);
    float2 auv = (float2(idx % 16, idx / 16) + f) / float2(16.0, 6.0);
    float a = atlas.sample(s, auv).r;
    float inten = g.g;
    float3 color;
    switch (u.scene) {
        case 0: color = float3(0.7, 1.0, 0.8); break;
        case 1: color = float3(0.5, 0.9, 1.0); break;
        case 2: color = inten > 0.95 ? float3(1.0, 1.0, 1.0) : float3(0.6, 1.0, 0.7); break;
        case 3: color = float3(1.0, 0.7, 0.3); break;
        case 4: color = float3(0.92, 0.93, 0.97); break;
        case 5: color = float3(0.8, 0.8, 0.9); break;
        default: color = u.scrollRow >= 0 && ij.y == u.scrollRow ? pal(c.x * 0.02 - u.time * 0.3) : float3(1.0, 0.92, 0.75); break;
    }
    return float4(color * a * inten, a * inten);
}

// ---------------------------------------------------------------- scene pass

fragment float4 sceneFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              texture2d<float> atlas [[texture(0)]], texture2d<float> grid [[texture(1)]],
                              sampler s [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(u.resolution.x / u.resolution.y, -1.0);
    float3 col;
    switch (u.scene) {
        case 0: col = sceneBoot(p, uv, u); break;
        case 1: col = scenePorts(p, u); break;
        case 2: col = scenePlasma(p, u); break;
        case 3: col = sceneTunnel(p, u); break;
        case 4: col = scenePanic(p, uv, u); break;
        case 5: col = sceneXNU(p, u); break;
        default: col = sceneCredits(p, uv, u); break;
    }
    float4 txt = textOverlay(uv, u, atlas, grid, s);
    col = col * (1 - txt.a * 0.7 * u.textAlpha) + txt.rgb * u.textAlpha;
    if (u.scene == 4 && u.sceneProgress > 0.78) {
        // dissolve: blocks drop out, then everything falls apart into the finale
        float k = (u.sceneProgress - 0.78) / 0.22;
        float2 b = floor(uv * float2(96, 54));
        float h = hash21(b);
        if (h < k * 1.1) col = 0;
        col *= 1 - smoothstep(0.85, 1.0, k);
    }
    return float4(col, 1);
}

// ---------------------------------------------------------------- post: bloom + CRT

fragment float4 brightFragment(VOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
    float3 c = src.sample(s, in.uv).rgb;
    float l = dot(c, float3(0.3, 0.59, 0.11));
    return float4(c * smoothstep(0.55, 1.2, l), 1);
}

fragment float4 blurFragment(VOut in [[stage_in]], constant float2& dir [[buffer(1)]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 px = dir / float2(src.get_width(), src.get_height());
    const float w[5] = {0.227, 0.194, 0.121, 0.054, 0.016};
    float3 c = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(s, in.uv + px * float(i) * 1.5).rgb * w[i];
        c += src.sample(s, in.uv - px * float(i) * 1.5).rgb * w[i];
    }
    return float4(c, 1);
}

fragment float4 postFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                             texture2d<float> scene [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                             sampler s [[sampler(0)]]) {
    float2 q = in.uv * 2 - 1;
    float curve = 0.06;
    q *= 1 + curve * dot(q, q);
    float2 uv = q * 0.5 + 0.5;
    if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1) return float4(0, 0, 0, 1);

    float flash = (u.scene == 4 ? u.snare + u.sceneProgress : u.kick * 0.6);
    float2 ca = (uv - 0.5) * (0.002 + 0.006 * flash);
    float3 col;
    col.r = scene.sample(s, uv + ca).r;
    col.g = scene.sample(s, uv).g;
    col.b = scene.sample(s, uv - ca).b;
    col += bloom.sample(s, uv).rgb * 0.9;

    float scan = 0.9 + 0.1 * sin(uv.y * u.resolution.y * PI);
    col *= scan;
    col *= 1 - 0.4 * pow(length(q) * 0.75, 3.0);
    col += (hash21(in.uv * 1000 + fract(u.time * 10) * 100) - 0.5) * 0.025;
    col = 1 - exp(-col * 1.3);
    col = pow(max(col, 0.0), 1 / 2.2);
    col *= u.transition;
    return float4(col, 1);
}
