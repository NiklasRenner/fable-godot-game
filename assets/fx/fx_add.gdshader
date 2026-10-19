// Textured effect particle drawn additively (fire, magic, sparks, glints): see fx_particle.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
#include "res://assets/fx/fx_particle.gdshaderinc"

void fragment() {
	vec4 c = fx_color(UV, COLOR);
	ALBEDO = c.rgb * c.a;
}
