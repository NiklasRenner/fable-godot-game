// Soft alpha-blended particle sprite (dust, smoke, mist): see sprite.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
#include "res://assets/fx/sprite.gdshaderinc"

void fragment() {
	vec4 c = sprite_color(UV, COLOR);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
