// Ground clutter cards (grass tufts, flowers): crossed alpha-cut quads that sway in the wind. The
// normal is forced straight up so the cards light like the ground they stand on (no dark
// backsides), the base is darkened a little to sit in the grass, and far cards dissolve away
// instead of shimmering.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D card : source_color, filter_linear_mipmap, repeat_disable;
uniform float sway = 0.07;          // metres the tips move
uniform float fade_start = 40.0;
uniform float fade_end = 55.0;

varying float fade;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float tip = 1.0 - UV.y;
	float wind = sin(TIME * 1.6 + wp.x * 0.35 + wp.z * 0.27) + 0.45 * sin(TIME * 3.3 + wp.x * 0.9 - wp.z * 0.4);
	VERTEX.x += wind * sway * tip * tip;
	VERTEX.z += wind * sway * 0.5 * tip * tip;
	NORMAL = vec3(0.0, 1.0, 0.0);
	fade = 1.0 - smoothstep(fade_start, fade_end, distance(wp, INV_VIEW_MATRIX[3].xyz));
}

void fragment() {
	vec4 c = texture(card, UV);
	ALBEDO = c.rgb * mix(0.65, 1.0, smoothstep(0.0, 0.6, 1.0 - UV.y));
	ALPHA = c.a;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz); // both faces: back faces would get it flipped
	ALPHA_SCISSOR_THRESHOLD = mix(1.01, 0.5, fade);
}
