// A ribbon effect: projectile and charge trails (FxTrail), swing arcs, the level-up helix, the
// shockwave rings and walls. UV.x runs along the ribbon (0 = head / start), UV.y across it.
// The streak texture (assets/fx/tex/trail.png) scrolls along it; `age` (per vertex, in COLOR.a,
// or the per-instance `progress` for meshes that age as a whole) erodes it from the tail, and
// the colour runs from a white-hot head through `tint` to `tail` (a darker shade of it).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D tex : filter_linear_mipmap, repeat_enable;
uniform float repeat = 1.0;      // streak texture repeats along the ribbon
uniform float scroll = 1.5;      // its speed along the ribbon
uniform float softness = 0.2;
uniform float head_hot = 0.8;    // how white the head burns
uniform float core_hot = 0.0;    // how white the middle of the band burns (rings, arcs)
uniform float along_fade = 0.35; // how much sooner the far end erodes (0: evenly, for rings)
uniform float intensity = 1.6;
instance uniform vec4 tint : source_color = vec4(1.0, 0.6, 0.2, 1.0);
instance uniform vec4 tail : source_color = vec4(0.6, 0.1, 0.0, 1.0);
instance uniform float progress = 0.0; // 0..1: whole-mesh age (rings, arcs)
instance uniform float seed = 0.0;

void fragment() {
	float age = clamp(max(1.0 - COLOR.a, progress), 0.0, 1.0);
	float along = UV.x;
	float across = abs(UV.y * 2.0 - 1.0);
	float d = texture(tex, vec2(along * repeat - TIME * scroll + seed, UV.y * 0.9 + 0.05)).r;
	d *= 1.0 - smoothstep(0.55, 1.0, across);              // soft long edges
	float e = age + along * along_fade;                      // the tail and the old erode first
	float a = smoothstep(e, e + softness, d);
	vec3 c = mix(tint.rgb, tail.rgb, smoothstep(0.1, 1.0, along * along_fade / 0.35 + age * 0.5));
	c = mix(c, vec3(1.0, 0.97, 0.9), head_hot * smoothstep(0.35, 0.0, along) * smoothstep(0.4, 0.9, d) * (1.0 - age));
	c = mix(c, vec3(1.0, 0.98, 0.92), core_hot * (1.0 - smoothstep(0.0, 0.45, across)) * smoothstep(0.3, 0.8, d) * (1.0 - age));
	ALBEDO = c * a * tint.a * intensity;
}
