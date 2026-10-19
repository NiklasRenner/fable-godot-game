// Classic-style flame on a quad (Flame.make crosses three of them): a teardrop that narrows
// upward, torn by two scrolling noise layers, coloured core -> orange -> red and drawn additively
// so where the quads cross it glows brighter. `phase` (per instance) keeps neighbours out of step.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform vec3 core : source_color = vec3(1.0, 0.92, 0.55);
uniform vec3 mid : source_color = vec3(1.0, 0.5, 0.1);
uniform vec3 edge : source_color = vec3(0.75, 0.13, 0.02);
uniform float speed = 1.3;
uniform float intensity = 1.5;
instance uniform float phase = 0.0;

void fragment() {
	float y = 1.0 - UV.y; // 0 at the base, 1 at the tip
	float t = TIME * speed + phase;
	float n = texture(noise_tex, vec2(UV.x * 1.3 + phase, y * 1.1 - t)).r;
	float n2 = texture(noise_tex, vec2(UV.x * 2.7 - phase, y * 2.3 - t * 1.8)).r;
	float x = (UV.x - 0.5) * 2.0 + (n - 0.5) * 0.7 * y; // the tip wavers, the base holds
	float width = 0.9 * pow(1.0 - y, 0.7);
	float body = 1.0 - smoothstep(width * 0.45, width, abs(x));
	body *= smoothstep(0.0, 0.1, y);
	float f = clamp(body * (0.6 + n2 * 0.9) - y * 0.45, 0.0, 1.0);
	vec3 col = mix(edge, mid, smoothstep(0.08, 0.4, f));
	col = mix(col, core, smoothstep(0.45, 0.85, f));
	ALBEDO = col * f * intensity;
}
