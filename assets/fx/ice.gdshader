// Ice (frost nova spikes, the frostbolt's shard): pale translucent blue with bright facet rims, a
// cold inner glow and a `melt` (per instance) that thins it away from the bottom up.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

uniform vec3 deep : source_color = vec3(0.25, 0.55, 0.95);
uniform vec3 pale : source_color = vec3(0.85, 0.95, 1.0);
instance uniform float melt = 0.0;
instance uniform float glow = 0.6;

void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	ALBEDO = mix(deep, pale, 0.35 + 0.65 * fres);
	EMISSION = mix(deep, pale, fres) * glow;
	ROUGHNESS = 0.12;
	SPECULAR = 0.9;
	ALPHA = clamp(0.55 + 0.45 * fres, 0.0, 1.0) * (1.0 - melt);
}
