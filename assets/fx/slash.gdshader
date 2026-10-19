// A weapon swing's arc: the mesh is a curved band (Vfx.arc_mesh: UV.x along the arc from where
// the swing starts, UV.y across it). `progress` (per instance, 0 -> 1.6) sweeps a bright leading
// edge along the arc: a painted streak (assets/fx/tex/streak.png) whose head rides the leading
// edge, its tail tapering behind, towards the outer (blade tip) side of the band.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D streaks : filter_linear_mipmap, repeat_enable;
instance uniform float progress = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.5, 1.0);
instance uniform float seed = 0.0;

void fragment() {
	// the painted streak (thick head on the right of the texture) runs along the arc with its head
	// at the leading edge, stretched over the last 70% of the swing behind it
	float behind = progress - UV.x;
	float u = 1.0 - behind / 0.7;
	float v = clamp((UV.y - 0.3) / 0.65, 0.0, 1.0);
	float d = texture(streaks, vec2(clamp(u, 0.0, 1.0), v)).r * step(0.0, behind) * step(0.0, u);
	d *= smoothstep(0.0, 0.15, UV.y - 0.3) * smoothstep(0.0, 0.08, 0.97 - UV.y);
	float fade = 1.0 - smoothstep(1.0, 1.6, progress);    // the whole arc fades as the swing ends
	float a = smoothstep(0.12, 0.5, d) * fade;
	float edge = smoothstep(0.75, 1.0, u);
	vec3 c = mix(tint.rgb, min(tint.rgb * 1.6, vec3(1.0)) + vec3(0.12), edge * 0.7 + smoothstep(0.6, 1.0, d) * 0.3);
	ALBEDO = c * a * tint.a * 1.3;
}
