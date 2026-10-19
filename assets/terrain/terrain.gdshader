// Classic-style terrain: four tiling hand-painted layers blended per vertex. Terrain.gd writes the
// weights into the vertex colour: r = dry grass, g = dirt road, b = rock, grass is the rest. The
// layers are sampled in world space (the terrain has no UVs), rock triplanar so steep slopes don't
// smear. A large, slow noise varies the tint and mixes in a second, rotated sampling of each layer
// so the repeat isn't visible from a distance. With `cave_paint` the vertex colour is instead the
// cave bake's own rock -> grass paint (tools/build_cave.py ROCK_COLOR/GRASS_COLOR): the hill over the
// warren then wears the same layers as the terrain it blends into.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D grass : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dry : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro : filter_linear, repeat_enable; // seamless noise, ~1 repeat per 64 m
uniform float tile_size = 4.0;      // metres per repeat of the ground layers
uniform float rock_tile_size = 6.0;
uniform float tint_strength = 0.18; // how much the macro noise varies brightness
uniform float edge_sharpness = 3.0; // > 1: blend edges follow the textures' light/dark (painted look)
uniform bool cave_paint = false;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// One layer at two scales/rotations, mixed by the macro noise: kills the visible grid.
vec3 layer(sampler2D tex, vec2 p, float m) {
	vec3 a = texture(tex, p).rgb;
	vec2 q = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p * 0.61 + vec2(0.37, 0.71);
	vec3 b = texture(tex, q).rgb;
	return mix(a, b, smoothstep(0.35, 0.65, m));
}

vec3 rock_triplanar(vec3 p, vec3 n, float m) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	p /= rock_tile_size;
	return layer(rock, p.zy, m) * w.x + layer(rock, p.xz, m) * w.y + layer(rock, p.xy, m) * w.z;
}

float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }

void fragment() {
	vec2 p = world_pos.xz / tile_size;
	float m = texture(macro, world_pos.xz / 64.0).r;
	vec3 g = layer(grass, p, m);
	vec3 d = layer(dry, p, m);
	vec3 r = layer(dirt, p * 0.8, m);
	vec3 k = rock_triplanar(world_pos, normalize(world_normal), m);
	vec4 w = vec4(max(0.0, 1.0 - COLOR.r - COLOR.g - COLOR.b), COLOR.r, COLOR.g, COLOR.b);
	if (cave_paint) {
		float grassy = clamp((0.30 - COLOR.r) / 0.17, 0.0, 1.0); // rock r 0.30 -> grass r 0.13
		w = vec4(grassy * 0.7, grassy * 0.3, 0.0, 1.0 - grassy);
	}
	// Height-blend: brighter texels of a layer win where weights are close, so the borders look
	// painted (tufts reaching into the road) instead of a soft airbrushed fade.
	w *= pow(vec4(lum(g), lum(d), lum(r), lum(k)) + 0.5, vec4(edge_sharpness));
	w = pow(w, vec4(2.0));
	w /= max(1e-4, w.x + w.y + w.z + w.w);
	vec3 col = g * w.x + d * w.y + r * w.z + k * w.w;
	col *= 1.0 + (m - 0.5) * 2.0 * tint_strength;
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
