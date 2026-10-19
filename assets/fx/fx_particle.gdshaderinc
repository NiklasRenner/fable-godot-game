// Shared body of the textured effect particles (fx_add / fx_mix), the main brush of the spell
// effects (Vfx, built through FxKit.emitter with a "tex"). A camera-facing quad (or, with
// streak > 0, a quad stretched along the particle's velocity) showing one cell of a greyscale
// density atlas from assets/fx/tex/ (tools/build_fx_textures.py):
//   - each particle keeps one random cell (variants) and spins by its particle angle;
//   - the process material's colour ramp gives colour (rgb) and presence (alpha), and presence is
//     spent as EROSION: the thin parts of the shape vanish first, so a puff tears into wisps
//     instead of fading as a flat disc;
//   - density also shades it: dense cores burn brighter (`hot`), thin edges darken
//     (`dark`), smoke uses the atlas's baked top light (G, `shade`);
//   - `distort` wobbles the lookup with scrolling noise (heat shimmer, licking flames).
// `tint` (per instance) colours a whole emitter.
uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform vec2 frames = vec2(1.0, 1.0);
uniform float spin_amount = 1.0; // how much of the particle angle turns the sprite (flames: barely)
uniform float streak = 0.0;
uniform float softness = 0.18;
uniform float distort = 0.0;
uniform float hot = 0.6;
uniform float dark = 0.5;
uniform float shade = 0.0;
uniform float intensity = 1.0;
uniform float fade = 0.0;       // 0: presence is spent only as erosion; 1: also as translucency (mist)
instance uniform vec4 tint : source_color = vec4(1.0);

varying float v_life;
varying float v_seed;
varying float v_angle;

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	float sx = length(MODEL_MATRIX[0].xyz);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	if (streak > 0.0) {
		vec3 axis = normalize(MODEL_MATRIX[1].xyz);
		vec3 side = normalize(cross(axis, normalize(cam - pos)));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(side * sx, 0.0), vec4(axis * sx * streak, 0.0),
			vec4(normalize(cross(side, axis)) * sx, 0.0), vec4(pos, 1.0));
	} else {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sx,
			INV_VIEW_MATRIX[2] * sx, vec4(pos, 1.0));
	}
	v_angle = INSTANCE_CUSTOM.x;
	v_life = INSTANCE_CUSTOM.w > 0.0 ? clamp(INSTANCE_CUSTOM.y / INSTANCE_CUSTOM.w, 0.0, 1.0) : 0.0;
	v_seed = fract(sin(float(INSTANCE_ID) * 12.9898 + pos.x * 0.001) * 43758.5453);
}

// density (r) and baked light (g) of this fragment's atlas cell
vec2 fx_sample(vec2 uv) {
	if (streak <= 0.0) {
		float c = cos(v_angle * spin_amount), s = sin(v_angle * spin_amount);
		uv = mat2(vec2(c, -s), vec2(s, c)) * (uv - 0.5) + 0.5;
	}
	if (distort > 0.0) {
		vec2 n = texture(noise, uv * 0.6 + vec2(v_seed * 7.0, -TIME * 0.6)).rg - 0.5;
		uv += n * distort * (0.4 + v_life);
	}
	uv = clamp(uv, 0.002, 0.998);
	float count = frames.x * frames.y;
	float idx = floor(v_seed * count);
	vec2 cell = vec2(mod(idx, frames.x), floor(idx / frames.x));
	return texture(tex, (uv + cell) / frames).rg;
}

// colour (rgb) and coverage (a) of the particle
vec4 fx_color(vec2 uv, vec4 col) {
	vec2 s = fx_sample(uv);
	float d = s.r;
	float e = 1.0 - col.a;                       // erosion threshold rises as presence falls
	float a = smoothstep(e, e + softness, d);
	vec3 base = col.rgb * tint.rgb;
	vec3 c = base * mix(1.0 - dark, 1.0, smoothstep(0.0, 0.55, d));
	c = mix(c, min(base * 1.7, vec3(1.0)) + vec3(0.12), hot * smoothstep(0.55, 1.0, d) * col.a);
	if (shade > 0.0) c *= mix(1.0, mix(0.55, 1.2, s.g), shade);
	return vec4(c * intensity, a * tint.a * mix(1.0, col.a, fade));
}
