// A column of light (level up): open cylinder, bright at the base and fading upward, with streaks
// rising through it. `fade` (per instance) takes it out.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.82, 0.35);
instance uniform float fade = 1.0;

void fragment() {
	float y = 1.0 - UV.y;
	float rise = fract(UV.x * 7.0 + sin(UV.x * 40.0) * 0.1);
	float streaks = smoothstep(0.45, 0.5, rise) * smoothstep(0.55, 0.5, rise);
	float scroll = 0.5 + 0.5 * sin(y * 18.0 - TIME * 9.0 + UV.x * 25.0);
	float a = pow(1.0 - y, 1.6) * (0.35 + 0.65 * streaks * scroll);
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.5);
	ALBEDO = color * a * (0.6 + rim) * fade * 0.9;
}
