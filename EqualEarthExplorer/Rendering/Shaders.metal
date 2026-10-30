#include <metal_stdlib>
using namespace metal;

// Uniform layouts. Must match `RasterUniforms` and `LineUniforms` in Renderer.swift.
// Only float4 and float4x4 members are used, so Swift and Metal agree on the layout.

struct RasterUniforms {
    float4x4 viewToGeo;      // upper-left 3 × 3: view frame → geographic
    float4 view;             // drawable width (px), height (px), scale (px per unit), mode (0 map, 1 globe)
    float4 options;          // has texture, Tissot enabled, Tissot radius (rad), Tissot grid step (rad)
    float4 oceanColor;       // used before the imagery is available
    float4 backgroundColor;
    float4 tissotColor;      // premultiplied is not required; alpha is the fill opacity
};

struct LineUniforms {
    float4x4 geoToView;      // geographic → view frame
    float4x4 frameToView;    // map frame → view frame
    float4 view;             // drawable width (px), height (px), scale (px per unit), mode
    float4 style;            // space (0 geographic, 1 map frame, 2 plane), half width (px), back-side alpha, unused
    float4 color;
};

struct Segment {
    float3 a;
    float3 b;
};

// Equal Earth constants (Šavrič, Patterson, Jenny, 2018).
constant float A1 = 1.340264;
constant float A2 = -0.081106;
constant float A3 = 0.000893;
constant float A4 = 0.003796;
constant float EE_M = 0.8660254037844386;        // √3 / 2
constant float Y_MAX = 1.3173627591574133;
constant float THETA_MAX = 1.0471975511965976;   // asin(√3 / 2) = π / 3

static float3x3 upper3x3(float4x4 m) {
    return float3x3(m[0].xyz, m[1].xyz, m[2].xyz);
}

static float2 ee_forward(float lambda, float phi) {
    float t = asin(EE_M * sin(phi));
    float t2 = t * t;
    float t6 = t2 * t2 * t2;
    float x = lambda * cos(t) / (EE_M * (A1 + 3.0 * A2 * t2 + t6 * (7.0 * A3 + 9.0 * A4 * t2)));
    float y = t * (A1 + A2 * t2 + t6 * (A3 + A4 * t2));
    return float2(x, y);
}

/// Inverse Equal Earth without early exits (keeps screen-space derivatives valid).
/// Returns (λ, φ); λ may exceed ±π and y may exceed ±Y_MAX for points outside the map.
static float2 ee_inverse(float2 p) {
    float y = clamp(p.y, -Y_MAX, Y_MAX);
    float t = y / A1;
    for (int i = 0; i < 6; i++) {
        float t2 = t * t;
        float t6 = t2 * t2 * t2;
        float f = t * (A1 + A2 * t2 + t6 * (A3 + A4 * t2)) - y;
        float fp = A1 + 3.0 * A2 * t2 + t6 * (7.0 * A3 + 9.0 * A4 * t2);
        t -= f / fp;
    }
    t = clamp(t, -THETA_MAX, THETA_MAX);
    float t2 = t * t;
    float t6 = t2 * t2 * t2;
    float lambda = EE_M * p.x * (A1 + 3.0 * A2 * t2 + t6 * (7.0 * A3 + 9.0 * A4 * t2)) / cos(t);
    float phi = asin(clamp(sin(t) / EE_M, -1.0, 1.0));
    return float2(lambda, phi);
}

static float3 unit_vector(float lambda, float phi) {
    float c = cos(phi);
    return float3(c * cos(lambda), c * sin(lambda), sin(phi));
}

// MARK: - Raster (imagery + Tissot fill)

struct RasterOut {
    float4 position [[position]];
};

/// One triangle that covers the whole drawable.
vertex RasterOut raster_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    RasterOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float4 earth_color(float3 g,
                          texture2d<float> earth,
                          sampler s,
                          constant RasterUniforms &u) {
    float lon = atan2(g.y, g.x);
    float lat = asin(clamp(g.z, -1.0, 1.0));

    float4 color;
    if (u.options.x > 0.5) {
        float2 uv = float2(lon / (2.0 * M_PI_F) + 0.5, 0.5 - lat / M_PI_F);
        // Remove the jump of u at the antimeridian, otherwise the GPU picks the smallest mipmap there.
        float2 dx = dfdx(uv);
        float2 dy = dfdy(uv);
        dx.x -= round(dx.x);
        dy.x -= round(dy.x);
        color = earth.sample(s, uv, gradient2d(dx, dy));
    } else {
        color = u.oceanColor;
    }

    if (u.options.y > 0.5) {
        float step = u.options.w;
        float latN = clamp(round(lat / step) * step, -M_PI_2_F, M_PI_2_F);
        float lonN = round(lon / step) * step;
        float ang = acos(clamp(dot(g, unit_vector(lonN, latN)), -1.0, 1.0));
        float fw = clamp(fwidth(ang), 1e-6, 0.01);
        float cover = clamp((u.options.z - ang) / fw + 0.5, 0.0, 1.0);
        color.rgb = mix(color.rgb, u.tissotColor.rgb, cover * u.tissotColor.a);
    }
    return color;
}

fragment float4 raster_fragment(RasterOut in [[stage_in]],
                                constant RasterUniforms &u [[buffer(0)]],
                                texture2d<float> earth [[texture(0)]],
                                sampler s [[sampler(0)]]) {
    float2 size = u.view.xy;
    float scale = u.view.z;
    float2 p = float2(in.position.x - size.x * 0.5, size.y * 0.5 - in.position.y) / scale;
    float3x3 viewToGeo = upper3x3(u.viewToGeo);

    float3 v;
    float coverage;
    float shade = 1.0;
    if (u.view.w < 0.5) {
        // Map: inverse Equal Earth gives the map-frame direction.
        float2 lp = ee_inverse(p);
        float lambdaC = clamp(lp.x, -M_PI_F, M_PI_F);
        v = unit_vector(lambdaC, lp.y);
        // Signed edge function: negative inside the outline.
        float edge = max(abs(lp.x) / M_PI_F, abs(p.y) / Y_MAX) - 1.0;
        coverage = clamp(0.5 - edge / max(fwidth(edge), 1e-6), 0.0, 1.0);
    } else {
        // Globe: orthographic view along the view-frame x axis.
        float r2 = dot(p, p);
        float z = sqrt(max(0.0, 1.0 - r2));
        v = float3(z, p.x, p.y);
        coverage = clamp((1.0 - sqrt(r2)) * scale + 0.5, 0.0, 1.0);
        shade = 0.55 + 0.45 * z;
    }

    float4 color = earth_color(normalize(viewToGeo * v), earth, s, u);
    color.rgb *= shade;
    return float4(mix(u.backgroundColor.rgb, color.rgb, coverage), 1.0);
}

// MARK: - Lines (segments drawn as anti-aliased capsules)

struct LineOut {
    float4 position [[position]];
    float2 local;               // (along, across) in pixels, relative to the segment start
    float segLength [[flat]];
    float halfWidth [[flat]];
    float alpha [[flat]];
};

vertex LineOut line_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           const device Segment *segments [[buffer(0)]],
                           constant LineUniforms &u [[buffer(1)]]) {
    Segment seg = segments[iid];
    int space = int(u.style.x + 0.5);
    bool isMap = u.view.w < 0.5;
    bool visible = true;
    float alpha = 1.0;
    float2 pa;
    float2 pb;

    if (space == 2) {
        pa = seg.a.xy;
        pb = seg.b.xy;
    } else {
        float3x3 m = space == 0 ? upper3x3(u.geoToView) : upper3x3(u.frameToView);
        float3 va = m * seg.a;
        float3 vb = m * seg.b;
        if (isMap) {
            float la = atan2(va.y, va.x);
            float lb = atan2(vb.y, vb.x);
            // The segment crosses the cut line: drop it.
            if (abs(la - lb) > M_PI_F) { visible = false; }
            pa = ee_forward(la, asin(clamp(va.z, -1.0, 1.0)));
            pb = ee_forward(lb, asin(clamp(vb.z, -1.0, 1.0)));
        } else {
            pa = va.yz;
            pb = vb.yz;
            if (va.x < 0.0 || vb.x < 0.0) {
                if (u.style.z <= 0.0) { visible = false; } else { alpha = u.style.z; }
            }
        }
    }

    float2 size = u.view.xy;
    float scale = u.view.z;
    float2 sa = size * 0.5 + float2(pa.x, -pa.y) * scale;
    float2 sb = size * 0.5 + float2(pb.x, -pb.y) * scale;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float hw = u.style.y;
    float ext = hw + 1.0;

    const float2 corners[6] = { float2(0, -1), float2(1, -1), float2(0, 1),
                                float2(0, 1), float2(1, -1), float2(1, 1) };
    float2 c = corners[vid];
    float along = c.x < 0.5 ? -ext : len + ext;
    float across = c.y * ext;
    float2 pix = sa + dir * along + nrm * across;

    LineOut out;
    out.position = visible ? float4(pix.x / size.x * 2.0 - 1.0, 1.0 - pix.y / size.y * 2.0, 0.0, 1.0)
                           : float4(2.0, 2.0, 0.0, 1.0);   // all corners equal: nothing is rasterised
    out.local = float2(along, across);
    out.segLength = len;
    out.halfWidth = hw;
    out.alpha = alpha;
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]],
                              constant LineUniforms &u [[buffer(1)]]) {
    float dx = max(max(-in.local.x, in.local.x - in.segLength), 0.0);
    float dist = length(float2(dx, in.local.y));
    float cover = clamp(in.halfWidth + 0.5 - dist, 0.0, 1.0);
    float a = u.color.a * cover * in.alpha;
    return float4(u.color.rgb * a, a);   // premultiplied alpha
}

// MARK: - Test support

/// Runs the GPU inverse projection for the parity unit test. Outside points give (1e9, 1e9).
kernel void ee_inverse_test(const device float2 *input [[buffer(0)]],
                            device float2 *output [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    float2 p = input[id];
    float2 lp = ee_inverse(p);
    bool inside = abs(p.y) <= Y_MAX && abs(lp.x) <= M_PI_F;
    output[id] = inside ? lp : float2(1e9, 1e9);
}
