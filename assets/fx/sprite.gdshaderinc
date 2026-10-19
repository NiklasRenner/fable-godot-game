// Shared body of the soft particle sprites (sprite_add / sprite_mix): a camera-facing quad with a
// round soft falloff and a hot centre. Particle colour and alpha come in through COLOR (the
// process material's colour ramp); `tint` (per instance) colours a whole emitter or mesh.
// streak > 0: instead of facing the camera fully, the quad turns about its own Y axis, which the
// process material aligns to the velocity (particle_flag_align_y), and is stretched along it:
// sparks that leave a short line in the direction they fly.
uniform float streak = 0.0;
uniform float hardness = 1.6;   // >1: tighter, brighter core
uniform float core = 0.35;      // how much of the centre burns white
instance uniform vec4 tint : source_color = vec4(1.0);

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
}

vec4 sprite_color(vec2 uv, vec4 col) {
	vec2 d = uv * 2.0 - 1.0;
	if (streak > 0.0) d.x *= 1.6; // a thinner line
	float r = length(d);
	float a = pow(clamp(1.0 - r, 0.0, 1.0), hardness);
	vec3 c = col.rgb * tint.rgb;
	c = mix(c, vec3(1.0), core * pow(clamp(1.0 - r * 1.8, 0.0, 1.0), 2.0));
	return vec4(c, a * col.a * tint.a);
}
