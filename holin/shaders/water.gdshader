shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_schlick_ggx;

// Agua estilizada y barata para el renderer mobile. Las ondas se calculan en
// coordenadas del mundo: no dependen del UV radial del CylinderMesh y conservan
// el mismo tamaño visual en todo el lago.

global uniform vec3 hole_position;
global uniform float hole_radius;

uniform vec4 deep_color : source_color = vec4(0.055, 0.24, 0.42, 1.0);
uniform vec4 surface_color : source_color = vec4(0.16, 0.55, 0.75, 1.0);
uniform vec4 crest_color : source_color = vec4(0.66, 0.91, 0.96, 1.0);
uniform vec4 foam_color : source_color = vec4(0.88, 0.98, 1.0, 1.0);
// Forma local del agua. Al usar coordenadas locales, el lago se puede mover
// libremente desde main.tscn sin tener que resincronizar el shader por código.
uniform vec2 lake_half_extents = vec2(12.0, 7.0);
uniform float corner_radius : hint_range(0.0, 4.0) = 1.8;
uniform float wave_scale : hint_range(0.1, 3.0) = 0.72;
uniform float wave_speed : hint_range(0.0, 3.0) = 0.55;

varying vec3 world_pos;
varying vec2 lake_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	lake_pos = VERTEX.xz;
}

float rounded_box_sdf(vec2 p, vec2 half_extents, float radius) {
	vec2 q = abs(p) - (half_extents - vec2(radius));
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	float hole_dist = distance(world_pos.xz, hole_position.xz);
	if (hole_dist < hole_radius) {
		discard;
	}
	float edge_distance = -rounded_box_sdf(lake_pos, lake_half_extents, corner_radius);
	if (edge_distance < 0.0) {
		discard;
	}

	vec2 p = world_pos.xz * wave_scale;
	float t = TIME * wave_speed;

	// Tres trenes de onda con direcciones y velocidades distintas rompen el
	// aspecto de franjas repetidas. El resultado funciona como textura animada.
	float a = sin(dot(p, vec2(0.82, 0.57)) * 1.05 + t * 1.55);
	float b = sin(dot(p, vec2(-0.38, 0.93)) * 1.48 - t * 1.18);
	float c = sin(dot(p, vec2(0.98, -0.18)) * 0.54 + t * 0.72);
	float waves = a * 0.48 + b * 0.30 + c * 0.22;

	// Crestas largas y curvas, no lunares: cada seno se deforma con otro seno y
	// luego se afina para dejar trazos blancos parecidos a reflejos sobre olas.
	float ridge_a = sin(
		dot(p, vec2(0.86, 0.52)) * 1.12
		+ sin(dot(p, vec2(-0.34, 0.94)) * 0.44 + t * 0.43) * 1.05
		+ t * 1.31
	);
	float ridge_b = sin(
		dot(p, vec2(-0.58, 0.81)) * 1.38
		+ sin(dot(p, vec2(0.96, 0.28)) * 0.36 - t * 0.35) * 0.85
		- t * 0.89
	);
	float breakup_a = smoothstep(-0.24, 0.70, sin(dot(p, vec2(-0.18, 0.98)) * 0.73 - t * 0.52));
	float breakup_b = smoothstep(-0.10, 0.76, sin(dot(p, vec2(0.92, 0.39)) * 0.58 + t * 0.38));
	float crests = clamp(
		pow(max(0.0, ridge_a), 15.0) * mix(0.20, 1.0, breakup_a)
		+ pow(max(0.0, ridge_b), 17.0) * 0.30 * breakup_b,
		0.0,
		1.0
	);

	float depth = smoothstep(0.0, min(lake_half_extents.x, lake_half_extents.y), edge_distance);
	vec3 water = mix(surface_color.rgb, deep_color.rgb, depth * 0.72);
	water *= 0.94 + waves * 0.045;
	water = mix(water, crest_color.rgb, crests * 0.32);

	// Una espuma fina e irregular marca la costa. Además de vender el material,
	// separa visualmente el agua del asfalto y del césped circundante.
	float shore = 1.0 - smoothstep(0.0, 1.15, edge_distance);
	float shore_breakup = smoothstep(-0.10, 0.66, sin(edge_distance * 8.0 + waves * 1.8 - t * 2.4));
	float foam = shore * mix(0.42, 1.0, shore_breakup);
	water = mix(water, foam_color.rgb, foam * 0.72);

	ALBEDO = water;
	ROUGHNESS = mix(0.30, 0.15, crests);
	SPECULAR = 0.78;
	EMISSION = crest_color.rgb * crests * 0.035 + foam_color.rgb * foam * 0.09;
}
