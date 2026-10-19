// Glowing particle sprite, drawn additively (sparks, embers, magic): see sprite.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
#include "res://assets/fx/sprite.gdshaderinc"

void fragment() {
	vec4 c = sprite_color(UV, COLOR);
	ALBEDO = c.rgb * c.a;
}
