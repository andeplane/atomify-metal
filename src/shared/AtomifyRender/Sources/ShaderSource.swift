/// Metal shaders, compiled at run time with `MTLDevice.makeLibrary(source:)`
/// so the same source works under `swift build`, `swift test` and Xcode
/// without depending on SwiftPM's Metal resource compilation.
///
/// Library-wide choices are preprocessor macros (`MAX_VIEWS`, `REVERSE_Z`);
/// per-pipeline choices are function constants (`alphaToCoverage`,
/// `blendedEdges`).
///
/// Particles are camera-facing squares sized to cover the sphere's
/// silhouette; the fragment shader casts a ray against the sphere and
/// writes the hit point's depth, so spheres intersect each other and bonds
/// correctly. Bonds are cylinders trimmed to the part between the two
/// spheres, ray-cast the same way through one rectangle in front of them
/// (`BondProxy`), built in the vertex shader from the two particles' positions. Everything
/// happens in view space with the eye at the origin (perspective only).
///
/// Every proxy lies in front of the surface it stands for, so the depth a
/// fragment writes is never nearer than the proxy's own; declaring that
/// (conservative depth) keeps early depth testing on, so hidden particles
/// cost almost nothing.
///
/// Edges are antialiased analytically: the fragment's alpha is how much of
/// the pixel the silhouette covers, which alpha-to-coverage turns into a
/// multisample mask. Without multisampling, fragments under half coverage
/// are dropped.
enum ShaderSource {
    /// Buffer indices shared with the shader source.
    enum BufferIndex {
        static let particles = 0
        static let styles = 1
        static let radii = 2
        static let colors = 3
        static let views = 4
        static let frame = 5
        static let draw = 6
        static let bonds = 7
        static let bondColors = 8
        static let lines = 9
    }

    enum FunctionConstant {
        static let alphaToCoverage = 0
        static let blendedEdges = 1
    }

    static var metal: String {
        header + common + spheres + bonds + lines + postProcessing
    }

    static let header = """
    #include <metal_stdlib>
    using namespace metal;

    #ifndef MAX_VIEWS
    #define MAX_VIEWS 1
    #endif
    #ifndef REVERSE_Z
    #define REVERSE_Z 0
    #endif

    #if MAX_VIEWS > 1
    #define AMPLIFICATION_ARGUMENT , ushort amplificationID [[amplification_id]]
    #define VIEW_INDEX uint(amplificationID)
    #else
    #define AMPLIFICATION_ARGUMENT
    #define VIEW_INDEX 0u
    #endif

    // Proxies are in front of their surfaces: the written depth is farther,
    // which is smaller with reverse Z and larger without.
    #if REVERSE_Z
    #define CONSERVATIVE_DEPTH depth(less)
    #else
    #define CONSERVATIVE_DEPTH depth(greater)
    #endif

    constant bool alphaToCoverage [[function_constant(0)]];
    constant bool blendedEdges [[function_constant(1)]];

    """

    static let common = """
    struct Particle { packed_float3 position; uint styleFlags; };
    struct Style { float4 color; float4 params; };
    struct Bond { uint a; uint b; };
    struct LineSegment { float4 start; float4 end; float4 color; };
    struct ViewUniforms {
        float4x4 modelView;
        float4x4 projection;
        float4 lightDirection;  // xyz toward the light (view space), w pixels per point
        float4 params;          // x scene->view scale, y near plane, zw viewport pixels
    };
    struct FrameUniforms {
        float4 highlightColor;
        float4 nearFade;        // x gone, y full size, z highlight radius scale, w AO strength
        float4 bond;            // x radius, y max length
        uint4 options;          // x radii, y colors, z bond colors, w style count
    };
    struct DrawUniforms { float4 offset; };   // xyz image offset, w radius factor
    struct SSAOUniforms { float4x4 projection; float4 params; float4 screen; };
    struct CompositeUniforms { float4 params; float4 sizes; float4 outlineColor; };

    constant uint flagSelected = 1u;
    constant uint flagHidden = 2u;

    struct ColorOutput {
        float4 color [[color(0)]];
        float depth [[CONSERVATIVE_DEPTH]];
    };
    struct GBufferOutput {
        float4 color [[color(0)]];
        float4 normalDepth [[color(1)]];   // view normal, 1 / view depth
        float depth [[CONSERVATIVE_DEPTH]];
    };
    struct PickOutput {
        uint id [[color(0)]];
        float depth [[CONSERVATIVE_DEPTH]];
    };

    static float3 srgbToLinear(float3 c) {
        return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
    }

    static float4 unpackColor(uint packed) {
        float4 c = unpack_unorm4x8_to_float(packed);
        return float4(srgbToLinear(c.rgb), c.a);
    }

    /// Geometry closer than nearFade.y shrinks away, gone by nearFade.x.
    static float nearFadeFactor(float3 viewPosition, constant FrameUniforms &frame) {
        if (frame.nearFade.y <= 0.0) {
            return 1.0;
        }
        return smoothstep(frame.nearFade.x, frame.nearFade.y, length(viewPosition));
    }

    /// Fraction of the pixel inside a silhouette, from a signed distance
    /// that is positive inside.
    static float coverage(float edge) {
        return saturate(edge / max(fwidth(edge), 1e-7) + 0.5);
    }

    static bool keepFragment(float alpha) {
        return (alphaToCoverage || blendedEdges) ? alpha > 0.0 : alpha >= 0.5;
    }

    static float outputAlpha(float alpha) {
        return (alphaToCoverage || blendedEdges) ? alpha : 1.0;
    }

    struct ParticleInfo {
        float3 center;
        float radius;
        float4 color;
        uint flags;
        float ambient;
    };

    static ParticleInfo loadParticle(uint index, const device Particle *particles,
                                     const device Style *styles, const device float *radii,
                                     const device uint *colors, constant FrameUniforms &frame) {
        Particle p = particles[index];
        uint style = min(p.styleFlags & 0xFFFFu, frame.options.w - 1u);
        ParticleInfo info;
        info.center = float3(p.position);
        info.radius = frame.options.x != 0u ? radii[index] : styles[style].params.x;
        info.color = frame.options.y != 0u ? unpackColor(colors[index]) : styles[style].color;
        info.flags = (p.styleFlags >> 16) & 0xFFu;
        // Density occlusion, scaled by the current strength.
        info.ambient = mix(1.0, float(p.styleFlags >> 24) / 255.0, saturate(frame.nearFade.w));
        if ((info.flags & flagSelected) != 0u) {
            info.radius *= frame.nearFade.z;
            info.color = float4(mix(info.color.rgb, frame.highlightColor.rgb, 0.6)
                                + 0.15 * frame.highlightColor.rgb, 1.0);
            info.ambient = 1.0;
        }
        return info;
    }

    /// A warm key light, a cool sky and dim ground for ambient, a Fresnel
    /// weighted highlight and a faint rim so silhouettes separate in dense
    /// material. `ambient` (the particle's crowding) takes away most of the
    /// sky and ground light but only a little of the key light, so crowded
    /// regions read as deeper without turning dark and murky.
    static float3 shade(float3 hit, float3 normal, float3 base, float ambient, constant ViewUniforms &view) {
        float3 l = normalize(view.lightDirection.xyz);
        float3 v = -normalize(hit);
        float ndl = dot(normal, l);
        float diffuse = saturate((ndl + 0.15) / 1.15);
        // Crowding mostly takes away ambient (sky and ground) light; the key
        // light still reaches what the eye sees, dimmed a little so crowded
        // regions read as deeper without turning murky.
        float crowding = smoothstep(0.45, 1.0, ambient);
        float fillOcclusion = mix(0.2, 1.0, crowding);
        float keyOcclusion = mix(0.75, 1.0, crowding);
        float3 key = float3(1.0, 0.96, 0.9) * diffuse;
        float sky = 0.5 + 0.5 * normal.y;
        float3 fill = mix(float3(0.10, 0.09, 0.085), float3(0.30, 0.33, 0.38), sky);
        float3 h = normalize(l + v);
        float nv = saturate(dot(normal, v));
        float fresnel = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        float specular = pow(saturate(dot(normal, h)), 64.0) * (0.35 + 0.65 * fresnel);
        float rim = pow(1.0 - nv, 3.0) * 0.08;
        float3 color = base * (key * (0.95 * keyOcclusion) + fill * fillOcclusion)
                       + (specular + rim) * keyOcclusion;
        return color / (1.0 + 0.18 * color);
    }

    static float clipDepth(float3 hit, constant ViewUniforms &view) {
        float4 clip = view.projection * float4(hit, 1.0);
        return clip.z / clip.w;
    }

    """

    static let spheres = """
    struct SphereVaryings {
        float4 position [[position]];
        float3 viewPosition;
        float3 center [[flat]];
        float radius [[flat]];
        float4 color [[flat]];
        float ambient [[flat]];
        uint id [[flat]];
        uint viewIndex [[flat]];
    };

    vertex SphereVaryings sphereVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                       const device Particle *particles [[buffer(0)]],
                                       const device Style *styles [[buffer(1)]],
                                       const device float *radii [[buffer(2)]],
                                       const device uint *colors [[buffer(3)]],
                                       constant ViewUniforms *views [[buffer(4)]],
                                       constant FrameUniforms &frame [[buffer(5)]],
                                       constant DrawUniforms &draw [[buffer(6)]]
                                       AMPLIFICATION_ARGUMENT) {
        uint viewIndex = VIEW_INDEX;
        constant ViewUniforms &view = views[viewIndex];
        ParticleInfo info = loadParticle(instanceID, particles, styles, radii, colors, frame);
        float3 center = (view.modelView * float4(info.center + draw.offset.xyz, 1.0)).xyz;
        float radius = info.radius * draw.offset.w * view.params.x * nearFadeFactor(center, frame);
        if ((info.flags & flagHidden) != 0u) {
            radius = 0.0;
        }
        float centerDistance = length(center);
        SphereVaryings out;
        out.center = center;
        out.radius = radius;
        out.color = info.color;
        out.ambient = info.ambient;
        out.id = instanceID + 1u;
        out.viewIndex = viewIndex;
        out.viewPosition = center;
        out.position = float4(0.0, 0.0, 0.0, 1.0);
        if (!(radius > 0.0) || centerDistance <= radius * 1.001) {
            return out;    // all four corners coincide: nothing is drawn
        }
        // A square facing the eye at the front of the sphere, just large
        // enough to cover the cone of rays that touch it, plus a margin of a
        // few pixels for the antialiased edge.
        float3 forward = center / centerDistance;
        float3 helper = abs(forward.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        float3 right = normalize(cross(helper, forward));
        float3 up = cross(forward, right);
        float front = centerDistance - radius;
        float halfSize = front * radius / sqrt(centerDistance * centerDistance - radius * radius) + front * 0.003;
        float2 corner = float2((vertexID & 1u) != 0u ? 1.0 : -1.0, (vertexID & 2u) != 0u ? 1.0 : -1.0);
        float3 p = forward * front + (right * corner.x + up * corner.y) * halfSize;
        out.viewPosition = p;
        out.position = view.projection * float4(p, 1.0);
        return out;
    }

    struct SphereHit {
        float3 position;
        float3 normal;
        float alpha;
    };

    static SphereHit traceSphere(SphereVaryings in) {
        float3 rd = normalize(in.viewPosition);
        float b = dot(rd, in.center);
        // Squared distance from the center to the ray.
        float miss = max(dot(in.center, in.center) - b * b, 0.0);
        SphereHit hit;
        hit.alpha = coverage(in.radius - sqrt(miss));
        // Rays just outside the silhouette shade its rim.
        hit.position = rd * (b - sqrt(max(in.radius * in.radius - miss, 0.0)));
        hit.normal = normalize(hit.position - in.center);
        return hit;
    }

    fragment ColorOutput sphereFragment(SphereVaryings in [[stage_in]],
                                        constant ViewUniforms *views [[buffer(4)]]) {
        constant ViewUniforms &view = views[in.viewIndex];
        SphereHit hit = traceSphere(in);
        if (!keepFragment(hit.alpha)) {
            discard_fragment();
        }
        ColorOutput out;
        out.color = float4(shade(hit.position, hit.normal, in.color.rgb, in.ambient, view), outputAlpha(hit.alpha));
        out.depth = clipDepth(hit.position, view);
        return out;
    }

    fragment GBufferOutput sphereGBufferFragment(SphereVaryings in [[stage_in]],
                                                 constant ViewUniforms *views [[buffer(4)]]) {
        constant ViewUniforms &view = views[in.viewIndex];
        SphereHit hit = traceSphere(in);
        if (!keepFragment(hit.alpha)) {
            discard_fragment();
        }
        GBufferOutput out;
        out.color = float4(shade(hit.position, hit.normal, in.color.rgb, in.ambient, view), outputAlpha(hit.alpha));
        out.normalDepth = float4(hit.normal, 1.0 / max(-hit.position.z, 1e-6));
        out.depth = clipDepth(hit.position, view);
        return out;
    }

    fragment PickOutput spherePickFragment(SphereVaryings in [[stage_in]],
                                           constant ViewUniforms *views [[buffer(4)]]) {
        constant ViewUniforms &view = views[in.viewIndex];
        SphereHit hit = traceSphere(in);
        if (hit.alpha < 0.5) {
            discard_fragment();
        }
        PickOutput out;
        out.id = in.id;
        out.depth = clipDepth(hit.position, view);
        return out;
    }

    """

    static var bonds: String {
        """
        // The bond proxy: see BondProxy.swift, which does the same in Swift.

        struct BondVaryings {
            float4 position [[position]];
            float3 viewPosition;
            float3 start [[flat]];
            float3 axis [[flat]];
            float axisLength [[flat]];
            float radius [[flat]];
            float split [[flat]];
            float4 startColor [[flat]];
            float4 endColor [[flat]];
            float startAmbient [[flat]];
            float endAmbient [[flat]];
            uint viewIndex [[flat]];
        };

        /// How far into a sphere the cylinder runs before its surface leaves it.
        static float insideDepth(float sphereRadius, float bondRadius) {
            return sphereRadius > bondRadius ? sqrt(sphereRadius * sphereRadius - bondRadius * bondRadius) : 0.0;
        }

        /// Where a sphere projects onto the plane at `planeDepth`, along and
        /// across the in-plane directions: exact (BondProxy.projectedExtent).
        static void projectedExtents(float3 center, float depth, float radius, float2 along, float2 across,
                                     float planeDepth, thread float2 &low, thread float2 &high) {
            float2 a = float2(dot(center.xy, along), dot(center.xy, across));
            float2 s = sqrt(max(a * a + depth * depth - radius * radius, 0.0));
            float scale = planeDepth / (depth * depth - radius * radius);
            low = (a * depth - radius * s) * scale;
            high = (a * depth + radius * s) * scale;
        }

        vertex BondVaryings bondVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                       const device Particle *particles [[buffer(0)]],
                                       const device Style *styles [[buffer(1)]],
                                       const device float *radii [[buffer(2)]],
                                       const device uint *colors [[buffer(3)]],
                                       constant ViewUniforms *views [[buffer(4)]],
                                       constant FrameUniforms &frame [[buffer(5)]],
                                       constant DrawUniforms &draw [[buffer(6)]],
                                       const device Bond *bonds [[buffer(7)]],
                                       const device uint *bondColors [[buffer(8)]]
                                       AMPLIFICATION_ARGUMENT) {
            uint viewIndex = VIEW_INDEX;
            constant ViewUniforms &view = views[viewIndex];
            Bond bond = bonds[instanceID];
            ParticleInfo pa = loadParticle(bond.a, particles, styles, radii, colors, frame);
            ParticleInfo pb = loadParticle(bond.b, particles, styles, radii, colors, frame);
            float3 a = (view.modelView * float4(pa.center + draw.offset.xyz, 1.0)).xyz;
            float3 b = (view.modelView * float4(pb.center + draw.offset.xyz, 1.0)).xyz;
            float scale = view.params.x;
            float fadeA = nearFadeFactor(a, frame);
            float fadeB = nearFadeFactor(b, frame);
            float radius = frame.bond.x * scale * min(fadeA, fadeB);
            float sceneLength = length(pb.center - pa.center);
            float3 d = b - a;
            float axisLength = length(d);

            BondVaryings out;
            out.position = float4(0.0, 0.0, 0.0, 1.0);
            out.viewPosition = a;
            out.start = a;
            out.axis = float3(0.0, 1.0, 0.0);
            out.axisLength = 0.0;
            out.radius = radius;
            out.split = 0.5;
            bool useBondColor = frame.options.z != 0u;
            float4 bondColor = useBondColor ? unpackColor(bondColors[instanceID]) : float4(1.0);
            out.startColor = useBondColor ? bondColor : pa.color;
            out.endColor = useBondColor ? bondColor : pb.color;
            out.startAmbient = pa.ambient;
            out.endAmbient = pb.ambient;
            out.viewIndex = viewIndex;
            bool hidden = ((pa.flags | pb.flags) & flagHidden) != 0u;
            if (hidden || sceneLength > frame.bond.y || axisLength < 1e-6 || !(radius > 0.0)) {
                return out;    // all four corners coincide: nothing is drawn
            }
            // Only the part between the two sphere surfaces can be seen.
            float ra = pa.radius * draw.offset.w * scale * fadeA;
            float rb = pb.radius * draw.offset.w * scale * fadeB;
            float3 axis = d / axisLength;
            float s0 = insideDepth(ra, radius);
            float s1 = axisLength - insideDepth(rb, radius);
            if (s1 <= s0) {
                return out;
            }
            float3 p0 = a + axis * s0;
            float3 p1 = a + axis * s1;
            // Half the box around the cylinder, with a margin of a few pixels
            // for the antialiased edge.
            float margin = radius + 0.003 * length(0.5 * (p0 + p1));
            // Keep the whole box in front of the near plane.
            float minimumDepth = view.params.y * 1.001 + 1.5 * margin;
            float depth0 = -p0.z, depth1 = -p1.z;
            if (depth0 < minimumDepth && depth1 < minimumDepth) {
                return out;
            }
            if (depth0 < minimumDepth) {
                p0 = mix(p0, p1, (minimumDepth - depth0) / (depth1 - depth0));
            } else if (depth1 < minimumDepth) {
                p1 = mix(p0, p1, (minimumDepth - depth0) / (depth1 - depth0));
            }
            // The color changes halfway along the visible part, between the
            // two spheres' surfaces.
            float start = dot(p0 - a, axis);
            float segmentLength = dot(p1 - a, axis) - start;
            if (!(segmentLength > 1e-6)) {
                return out;
            }
            float splitDistance = ra + 0.5 * (axisLength - ra - rb);
            out.split = saturate((splitDistance - start) / segmentLength);

            // The capsule of radius `margin` around the segment contains the
            // cylinder, and projects within the hull of its two end spheres'
            // projections. Cover them with a rectangle in the plane of the
            // capsule's nearest depth, aligned with the projected axis,
            // spanning each sphere's exact extent along and across it.
            depth0 = -p0.z;
            depth1 = -p1.z;
            float planeDepth = min(depth0, depth1) - margin;
            float2 alongAxis = p1.xy / depth1 - p0.xy / depth0;
            float alongLength = length(alongAxis);
            float2 along = alongLength > 1e-9 ? alongAxis / alongLength : float2(1.0, 0.0);
            float2 across = float2(-along.y, along.x);
            float2 low, high;
            projectedExtents(p0, depth0, margin, along, across, planeDepth, low, high);
            float2 low1, high1;
            projectedExtents(p1, depth1, margin, along, across, planeDepth, low1, high1);
            low = min(low, low1);
            high = max(high, high1);
            float u = (vertexID & 1u) != 0u ? high.x : low.x;
            float v = (vertexID & 2u) != 0u ? high.y : low.y;
            float3 p = float3(along * u + across * v, -planeDepth);
            out.start = p0;
            out.axis = axis;
            out.axisLength = segmentLength;
            out.viewPosition = p;
            out.position = view.projection * float4(p, 1.0);
            return out;
        }

        struct BondHit {
            float3 position;
            float3 normal;
            float alpha;
            float s;
            bool valid;
        };

        static BondHit traceBond(BondVaryings in) {
            BondHit hit;
            hit.valid = false;
            hit.position = float3(0.0);
            hit.normal = float3(0.0, 0.0, 1.0);
            hit.s = 0.0;
            float3 rd = normalize(in.viewPosition);
            float3 oc = -in.start;
            float3 dPerp = rd - dot(rd, in.axis) * in.axis;
            float3 oPerp = oc - dot(oc, in.axis) * in.axis;
            float a = dot(dPerp, dPerp);
            float b = dot(dPerp, oPerp);
            // Squared distance between the ray and the axis.
            float miss = max(dot(oPerp, oPerp) - b * b / max(a, 1e-12), 0.0);
            hit.alpha = coverage(in.radius - sqrt(miss));
            if (a < 1e-12) {
                return hit;
            }
            float c = dot(oPerp, oPerp) - in.radius * in.radius;
            float t = (-b - sqrt(max(b * b - a * c, 0.0))) / a;
            if (t <= 0.0) {
                return hit;
            }
            hit.position = rd * t;
            hit.s = dot(hit.position - in.start, in.axis);
            if (hit.s < 0.0 || hit.s > in.axisLength) {
                return hit;
            }
            hit.normal = normalize(hit.position - in.start - hit.s * in.axis);
            hit.valid = true;
            return hit;
        }

        fragment ColorOutput bondFragment(BondVaryings in [[stage_in]],
                                          constant ViewUniforms *views [[buffer(4)]]) {
            constant ViewUniforms &view = views[in.viewIndex];
            BondHit hit = traceBond(in);
            if (!hit.valid || !keepFragment(hit.alpha)) {
                discard_fragment();
            }
            bool first = hit.s < in.split * in.axisLength;
            float4 base = first ? in.startColor : in.endColor;
            float ambient = first ? in.startAmbient : in.endAmbient;
            ColorOutput out;
            out.color = float4(shade(hit.position, hit.normal, base.rgb, ambient, view), outputAlpha(hit.alpha));
            out.depth = clipDepth(hit.position, view);
            return out;
        }

        fragment GBufferOutput bondGBufferFragment(BondVaryings in [[stage_in]],
                                                   constant ViewUniforms *views [[buffer(4)]]) {
            constant ViewUniforms &view = views[in.viewIndex];
            BondHit hit = traceBond(in);
            if (!hit.valid || !keepFragment(hit.alpha)) {
                discard_fragment();
            }
            bool first = hit.s < in.split * in.axisLength;
            float4 base = first ? in.startColor : in.endColor;
            float ambient = first ? in.startAmbient : in.endAmbient;
            GBufferOutput out;
            out.color = float4(shade(hit.position, hit.normal, base.rgb, ambient, view), outputAlpha(hit.alpha));
            out.normalDepth = float4(hit.normal, 1.0 / max(-hit.position.z, 1e-6));
            out.depth = clipDepth(hit.position, view);
            return out;
        }

        fragment PickOutput bondPickFragment(BondVaryings in [[stage_in]],
                                             constant ViewUniforms *views [[buffer(4)]]) {
            constant ViewUniforms &view = views[in.viewIndex];
            BondHit hit = traceBond(in);
            if (!hit.valid || hit.alpha < 0.5) {
                discard_fragment();
            }
            PickOutput out;
            out.id = 0u;    // bonds hide particles behind them but are not picked
            out.depth = clipDepth(hit.position, view);
            return out;
        }

        """
    }

    static let lines = """
    struct LineVaryings {
        float4 position [[position]];
        float edge;                 // pixels from the center line
        float viewDepth;
        float halfWidth [[flat]];   // pixels
        float4 color [[flat]];
        uint viewIndex [[flat]];
    };

    vertex LineVaryings lineVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                   constant ViewUniforms *views [[buffer(4)]],
                                   const device LineSegment *segments [[buffer(9)]]
                                   AMPLIFICATION_ARGUMENT) {
        uint viewIndex = VIEW_INDEX;
        constant ViewUniforms &view = views[viewIndex];
        LineSegment segment = segments[instanceID];
        float3 a = (view.modelView * float4(segment.start.xyz, 1.0)).xyz;
        float3 b = (view.modelView * float4(segment.end.xyz, 1.0)).xyz;
        LineVaryings out;
        out.position = float4(0.0, 0.0, 0.0, 1.0);
        out.edge = 0.0;
        out.viewDepth = 1.0;
        out.halfWidth = 0.0;
        out.color = segment.color;
        out.viewIndex = viewIndex;
        // Clip to the near plane before expanding in screen space.
        float nearZ = -view.params.y * 1.001;
        if (a.z > nearZ && b.z > nearZ) {
            return out;
        }
        if (a.z > nearZ) {
            a = mix(a, b, (a.z - nearZ) / (a.z - b.z));
        } else if (b.z > nearZ) {
            b = mix(b, a, (b.z - nearZ) / (b.z - a.z));
        }
        float4 ca = view.projection * float4(a, 1.0);
        float4 cb = view.projection * float4(b, 1.0);
        float2 halfViewport = max(view.params.zw, float2(1.0)) * 0.5;
        float2 sa = ca.xy / ca.w * halfViewport;
        float2 sb = cb.xy / cb.w * halfViewport;
        float2 direction = sb - sa;
        float span = length(direction);
        direction = span > 1e-6 ? direction / span : float2(1.0, 0.0);
        float2 normal = float2(-direction.y, direction.x);
        float halfWidth = 0.5 * segment.start.w * max(view.lightDirection.w, 1e-3);
        // One extra pixel each side for the antialiased edge.
        float extent = halfWidth + 1.0;
        bool atEnd = (vertexID & 2u) != 0u;
        float side = (vertexID & 1u) != 0u ? 1.0 : -1.0;
        float4 c = atEnd ? cb : ca;
        float3 v = atEnd ? b : a;
        c.xy += normal * (side * extent) / halfViewport * c.w;
        out.position = c;
        out.edge = side * extent;
        out.viewDepth = -v.z;
        out.halfWidth = halfWidth;
        return out;
    }

    fragment float4 lineFragment(LineVaryings in [[stage_in]]) {
        float alpha = saturate(in.halfWidth + 0.5 - abs(in.edge));
        if (!keepFragment(alpha)) {
            discard_fragment();
        }
        return float4(in.color.rgb, outputAlpha(alpha) * in.color.a);
    }

    struct LineGBufferOutput {
        float4 color [[color(0)]];
        float4 normalDepth [[color(1)]];
    };

    fragment LineGBufferOutput lineGBufferFragment(LineVaryings in [[stage_in]]) {
        float alpha = saturate(in.halfWidth + 0.5 - abs(in.edge));
        if (!keepFragment(alpha)) {
            discard_fragment();
        }
        LineGBufferOutput out;
        out.color = float4(in.color.rgb, outputAlpha(alpha) * in.color.a);
        // No normal: the occlusion pass leaves lines unshaded.
        out.normalDepth = float4(0.0, 0.0, 0.0, 1.0 / max(in.viewDepth, 1e-6));
        return out;
    }

    """

    static let postProcessing = """
    struct FullscreenVaryings {
        float4 position [[position]];
        float2 uv;
    };

    vertex FullscreenVaryings fullscreenVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(float((vertexID << 1) & 2u), float(vertexID & 2u));
        FullscreenVaryings out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    static float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    /// View-space position of a pixel (uv, top-left origin) at view depth
    /// `depth` (positive), for any perspective projection.
    static float3 viewPositionAt(float2 uv, float depth, float4x4 projection) {
        float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
        return float3(depth * (ndc.x + projection[2][0]) / projection[0][0],
                      depth * (ndc.y + projection[2][1]) / projection[1][1],
                      -depth);
    }

    /// Normal-oriented hemisphere occlusion. Writes (ambient light, view depth).
    fragment float4 ambientOcclusionFragment(FullscreenVaryings in [[stage_in]],
                                             texture2d<float> normalDepth [[texture(0)]],
                                             constant SSAOUniforms &u [[buffer(0)]],
                                             constant float4 *hemisphere [[buffer(1)]]) {
        constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
        float4 center = normalDepth.sample(nearestSampler, in.uv);
        if (center.w <= 0.0) {
            return float4(1.0, 0.0, 0.0, 0.0);
        }
        float depth = 1.0 / center.w;
        if (dot(center.xyz, center.xyz) < 0.25) {
            return float4(1.0, depth, 0.0, 0.0);
        }
        float3 n = normalize(center.xyz);
        float3 p = viewPositionAt(in.uv, depth, u.projection);
        float angle = hash12(in.position.xy) * 6.2831853;
        float3 jitter = float3(cos(angle), sin(angle), 0.0);
        float3 tangent = jitter - n * dot(jitter, n);
        if (dot(tangent, tangent) < 1e-6) {
            tangent = cross(n, float3(0.0, 0.0, 1.0));
        }
        tangent = normalize(tangent);
        float3 bitangent = cross(n, tangent);
        float radius = u.params.x;
        float bias = u.params.z * depth + 0.025 * radius;
        int count = int(u.params.w);
        float occlusion = 0.0;
        for (int i = 0; i < count; i++) {
            float3 k = hemisphere[i].xyz;
            float3 s = p + (tangent * k.x + bitangent * k.y + n * k.z) * radius;
            float4 clip = u.projection * float4(s, 1.0);
            if (clip.w <= 0.0) {
                continue;
            }
            float2 suv = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
            float sampledInverse = normalDepth.sample(nearestSampler, suv).w;
            if (sampledInverse <= 0.0) {
                continue;
            }
            float sceneDepth = 1.0 / sampledInverse;
            float range = smoothstep(0.0, 1.0, radius / max(abs(depth - sceneDepth), 1e-6));
            occlusion += (sceneDepth <= -s.z - bias ? 1.0 : 0.0) * range;
        }
        float ao = 1.0 - occlusion / float(max(count, 1));
        return float4(pow(saturate(ao), u.params.y), depth, 0.0, 0.0);
    }

    /// Lit color times blurred occlusion (depth-aware), plus outlines where
    /// a neighbor is much farther away.
    fragment float4 compositeFragment(FullscreenVaryings in [[stage_in]],
                                      texture2d<float> colorTexture [[texture(0)]],
                                      texture2d<float> normalDepth [[texture(1)]],
                                      texture2d<float> occlusionTexture [[texture(2)]],
                                      constant CompositeUniforms &u [[buffer(0)]]) {
        constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
        float4 color = colorTexture.sample(nearestSampler, in.uv);
        float inverseDepth = normalDepth.sample(nearestSampler, in.uv).w;
        float3 rgb = color.rgb;
        if (inverseDepth > 0.0) {
            float depth = 1.0 / inverseDepth;
            if (u.params.w > 0.0) {
                float2 texel = 1.0 / max(u.sizes.zw, float2(1.0));
                float sum = 0.0;
                float weight = 0.0;
                for (int y = -2; y <= 2; y++) {
                    for (int x = -2; x <= 2; x++) {
                        float2 o = occlusionTexture.sample(nearestSampler, in.uv + float2(float(x), float(y)) * texel).rg;
                        if (o.y <= 0.0) {
                            continue;
                        }
                        float w = exp(-abs(o.y - depth) / (0.02 * depth + 1e-4));
                        sum += o.x * w;
                        weight += w;
                    }
                }
                if (weight > 1e-4) {
                    rgb *= sum / weight;
                }
            }
            if (u.params.x > 0.0) {
                float2 px = u.params.x / max(u.sizes.xy, float2(1.0));
                float2 offsets[4] = { float2(px.x, 0.0), float2(-px.x, 0.0), float2(0.0, px.y), float2(0.0, -px.y) };
                float edge = 0.0;
                for (int i = 0; i < 4; i++) {
                    float neighbor = normalDepth.sample(nearestSampler, in.uv + offsets[i]).w;
                    float neighborDepth = neighbor > 0.0 ? 1.0 / neighbor : 1e20;
                    edge = max(edge, smoothstep(u.params.y, 2.0 * u.params.y, neighborDepth - depth));
                }
                rgb = mix(rgb, u.outlineColor.rgb, edge * u.params.z);
            }
        }
        return float4(rgb, color.a);
    }

    """
}
