/// Metal shaders for the billboard renderer, compiled at run time so the
/// same source runs in the app and in the macOS tests.
///
/// Atoms are camera-facing squares sized to cover the sphere's silhouette;
/// the fragment shader casts a ray against the sphere and writes the hit
/// point's depth, so atoms intersect each other and bonds correctly instead
/// of looking like flat discs. Cylinders (bonds, box edges) do the same
/// inside a box around them. Everything happens in view space: the camera
/// sits at the origin, and depth is reverse Z (1 near, 0 far) as on Vision Pro.
///
/// Edges are antialiased analytically: each fragment outputs how much of
/// its pixel the silhouette covers as alpha, which alpha-to-coverage turns
/// into a multisample mask. The proxies are a little larger than the
/// shapes so the soft edge is not clipped.
///
/// Every proxy lies in front of the surface it stands for, so the depth a
/// fragment writes is never nearer than the proxy's own. Declaring that
/// (`depth(less)` with reverse Z) keeps early depth testing on: atoms hidden
/// behind others cost almost nothing, which matters with a million of them.
///
/// Anything closer than 30 cm to the eye shrinks away, gone by 15 cm,
/// since it can't be seen sharply there.
public enum ImpostorShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Atom { float4 centerRadius; float4 color; };
    struct Cylinder { float4 startRadius; float4 endSplit; float4 startColor; float4 endColor; };
    struct Uniforms {
        float4x4 modelView;     // simulation units to view space
        float4x4 projection;
        float4 lightDirection;  // view space, pointing toward the light
        float4 params;          // x: view-space length of one simulation unit,
                                // y: atom radius factor (larger for sparser copies)
    };

    struct Shaded {
        half4 color [[color(0)]];
        float depth [[depth(less)]];
    };

    /// Eyes can't converge on anything much closer than a hand's width, so
    /// atoms and bonds shrink to nothing between 30 and 15 cm from the eye
    /// instead of filling the view with something impossible to focus on.
    /// Shrinking keeps them solid: fading them through alpha-to-coverage
    /// turned them into a coarse screen-door pattern that shimmers in stereo.
    constant float comfortFar = 0.30;
    constant float comfortNear = 0.15;
    static float comfortFade(float3 hit) {
        return smoothstep(comfortNear, comfortFar, length(hit));
    }

    /// Fraction of the pixel inside a silhouette, from a signed distance
    /// that is positive inside.
    static float coverage(float edge) {
        return saturate(edge / max(fwidth(edge), 1e-7) + 0.5);
    }

    /// A warm key light from above, a cool sky and dim ground for ambient
    /// (all darkened by `ambient`, the atom's occlusion), a Fresnel weighted
    /// highlight and a faint rim so silhouettes separate in dense material.
    static Shaded shade(float3 hit, float3 normal, float3 rayDirection, float3 base, float ambient,
                        float alpha, constant Uniforms &u) {
        float3 l = normalize(u.lightDirection.xyz);
        float3 v = -rayDirection;
        float ndl = dot(normal, l);
        // Slightly wrapped diffuse keeps the terminator soft.
        float diffuse = saturate((ndl + 0.15) / 1.15);
        // Occlusion dims every light term alike, so atoms deep in a crowd
        // fall to about a tenth while exposed ones stay fully lit: pores and
        // surfaces read as shaded shapes rather than a flat sheet.
        float occlusion = mix(0.1, 1.0, smoothstep(0.45, 1.0, ambient));
        float3 key = float3(1.0, 0.96, 0.9) * diffuse;
        float sky = 0.5 + 0.5 * ndl;
        float3 fill = mix(float3(0.10, 0.09, 0.085), float3(0.30, 0.33, 0.38), sky);
        float3 h = normalize(l + v);
        float nv = saturate(dot(normal, v));
        float fresnel = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        float specular = pow(saturate(dot(normal, h)), 64.0) * (0.35 + 0.65 * fresnel);
        float rim = pow(1.0 - nv, 3.0) * 0.08;
        float3 color = (base * (key * 0.95 + fill) + specular + rim) * occlusion;
        // Soft shoulder instead of clipping bright highlights.
        color = color / (1.0 + 0.18 * color);
        float4 clip = u.projection * float4(hit, 1.0);
        Shaded out;
        out.color = half4(half3(color), half(alpha));
        out.depth = clip.z / clip.w;
        return out;
    }

    struct AtomVaryings {
        float4 position [[position]];
        float3 viewPosition;
        float3 center [[flat]];
        float radius [[flat]];
        float4 color [[flat]];    // linear RGB, ambient occlusion
    };

    vertex AtomVaryings atomVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                   const device Atom *atoms [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
        Atom atom = atoms[instanceID];
        float3 center = (u.modelView * float4(atom.centerRadius.xyz, 1.0)).xyz;
        float radius = atom.centerRadius.w * u.params.x * u.params.y * comfortFade(center);
        float distance = length(center);
        AtomVaryings out;
        out.center = center;
        out.radius = radius;
        out.color = atom.color;
        out.viewPosition = center;
        out.position = float4(0.0, 0.0, 0.0, 1.0);
        if (radius <= 0.0 || distance <= radius * 1.001) {
            return out;    // all four corners coincide: nothing is drawn
        }
        // A square facing the camera at the front of the sphere, just large
        // enough to cover the cone of rays that touch it.
        float3 forward = center / distance;
        float3 helper = abs(forward.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        float3 right = normalize(cross(helper, forward));
        float3 up = cross(forward, right);
        float front = distance - radius;
        // Plus a margin of a few pixels for the antialiased edge.
        float halfSize = front * radius / sqrt(distance * distance - radius * radius) + front * 0.003;
        float2 corner = float2((vertexID & 1) ? 1.0 : -1.0, (vertexID & 2) ? 1.0 : -1.0);
        float3 p = forward * front + (right * corner.x + up * corner.y) * halfSize;
        out.viewPosition = p;
        out.position = u.projection * float4(p, 1.0);
        return out;
    }

    fragment Shaded atomFragment(AtomVaryings in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float3 rd = normalize(in.viewPosition);
        float b = dot(rd, in.center);
        // Squared distance from the center to the ray.
        float miss = max(dot(in.center, in.center) - b * b, 0.0);
        float alpha = coverage(in.radius - sqrt(miss));
        if (alpha <= 0.0) {
            discard_fragment();
        }
        // Rays just outside the silhouette shade its rim.
        float3 hit = rd * (b - sqrt(max(in.radius * in.radius - miss, 0.0)));
        return shade(hit, normalize(hit - in.center), rd, in.color.rgb, in.color.a, alpha, u);
    }

    constant float3 cubeCorners[8] = {
        float3(-1, -1, -1), float3(1, -1, -1), float3(-1, 1, -1), float3(1, 1, -1),
        float3(-1, -1, 1), float3(1, -1, 1), float3(-1, 1, 1), float3(1, 1, 1)
    };
    constant ushort cubeIndices[36] = {
        0, 2, 1, 1, 2, 3,  4, 5, 6, 5, 7, 6,  0, 1, 4, 1, 5, 4,
        2, 6, 3, 3, 6, 7,  0, 4, 2, 2, 4, 6,  1, 3, 5, 3, 7, 5
    };

    struct CylinderVaryings {
        float4 position [[position]];
        float3 viewPosition;
        float3 start [[flat]];
        float3 axis [[flat]];
        float axisLength [[flat]];
        float radius [[flat]];
        float split [[flat]];
        float3 startColor [[flat]];
        float3 endColor [[flat]];
    };

    vertex CylinderVaryings cylinderVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                           const device Cylinder *cylinders [[buffer(0)]],
                                           constant Uniforms &u [[buffer(1)]]) {
        Cylinder cylinder = cylinders[instanceID];
        float3 a = (u.modelView * float4(cylinder.startRadius.xyz, 1.0)).xyz;
        float3 b = (u.modelView * float4(cylinder.endSplit.xyz, 1.0)).xyz;
        float radius = cylinder.startRadius.w * u.params.x * min(comfortFade(a), comfortFade(b));
        float3 d = b - a;
        float axisLength = length(d);
        CylinderVaryings out;
        out.start = a;
        out.radius = radius;
        out.split = cylinder.endSplit.w;
        out.startColor = cylinder.startColor.rgb;
        out.endColor = cylinder.endColor.rgb;
        out.axisLength = axisLength;
        out.axis = float3(0.0, 1.0, 0.0);
        out.viewPosition = a;
        out.position = float4(0.0, 0.0, 0.0, 1.0);
        if (axisLength < 1e-6 || radius <= 0.0) {
            return out;
        }
        float3 axis = d / axisLength;
        float3 helper = abs(axis.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        float3 side = normalize(cross(helper, axis));
        float3 other = cross(axis, side);
        float3 corner = cubeCorners[cubeIndices[vertexID]];
        // A margin of a few pixels for the antialiased edge.
        float margin = radius + 0.003 * length(a + d * 0.5);
        float3 p = a + axis * (axisLength * (corner.x * 0.5 + 0.5))
                     + side * (margin * corner.y) + other * (margin * corner.z);
        out.axis = axis;
        out.viewPosition = p;
        out.position = u.projection * float4(p, 1.0);
        return out;
    }

    fragment Shaded cylinderFragment(CylinderVaryings in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float3 rd = normalize(in.viewPosition);
        float3 oc = -in.start;
        float3 dPerp = rd - dot(rd, in.axis) * in.axis;
        float3 oPerp = oc - dot(oc, in.axis) * in.axis;
        float a = dot(dPerp, dPerp);
        float b = dot(dPerp, oPerp);
        if (a < 1e-12) {
            discard_fragment();
        }
        // Squared distance between the ray and the axis.
        float miss = max(dot(oPerp, oPerp) - b * b / a, 0.0);
        float alpha = coverage(in.radius - sqrt(miss));
        if (alpha <= 0.0) {
            discard_fragment();
        }
        float c = dot(oPerp, oPerp) - in.radius * in.radius;
        float t = (-b - sqrt(max(b * b - a * c, 0.0))) / a;
        if (t <= 0.0) {
            discard_fragment();
        }
        float3 hit = rd * t;
        float s = dot(hit - in.start, in.axis);
        if (s < 0.0 || s > in.axisLength) {
            discard_fragment();
        }
        float3 normal = normalize(hit - in.start - s * in.axis);
        float3 base = s < in.split * in.axisLength ? in.startColor : in.endColor;
        return shade(hit, normal, rd, base, 1.0, alpha, u);
    }
    """
}
