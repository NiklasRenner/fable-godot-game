// A unit's health bar over its head (Unit._build_nameplate): one quad, drawn in pixels of a
// 120 x 14 bar: black outline, a rim (gold for bosses), dark well, the fill in the unit's colour
// with a glossy top, and the recent damage as a pale chunk that drains after it (`lag`).
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled;

const vec2 PX = vec2(120.0, 14.0);
instance uniform float frac = 1.0;
instance uniform float lag = 1.0;
instance uniform vec4 fill : source_color = vec4(0.85, 0.15, 0.1, 1.0);
instance uniform vec4 rim : source_color = vec4(0.45, 0.42, 0.38, 1.0);

void fragment() {
	vec2 p = UV * PX;
	float e = min(min(p.x, p.y), min(PX.x - p.x, PX.y - p.y));
	vec3 c;
	if (e < 1.0) {
		c = vec3(0.0);
	} else if (e < 2.5) {
		c = rim.rgb * (UV.y < 0.5 ? 1.15 : 0.7);
	} else {
		float x = (p.x - 2.5) / (PX.x - 5.0);
		float y = (p.y - 2.5) / (PX.y - 5.0);
		float gloss = 1.15 - 0.55 * y + (y < 0.22 ? 0.25 : 0.0);
		if (x <= frac) {
			c = fill.rgb * gloss;
		} else if (x <= lag) {
			c = mix(fill.rgb, vec3(1.0, 0.95, 0.8), 0.65) * gloss;
		} else {
			c = vec3(0.06, 0.05, 0.05) * (1.3 - y * 0.6);
		}
	}
	ALBEDO = c;
	ALPHA = 0.95;
}
