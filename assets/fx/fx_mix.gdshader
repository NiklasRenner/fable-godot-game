// Textured effect particle, alpha blended (smoke, dust, mist, snow): see fx_particle.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
#include "res://assets/fx/fx_particle.gdshaderinc"

void fragment() {
	vec4 c = fx_color(UV, COLOR);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
