shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Suelo de la ciudad con la boca del pozo recortada de verdad: los fragmentos
// que caen adentro del radio del agujero se descartan, así se ve el pozo que
// hay abajo en vez de un disco negro pintado encima. La posición y el radio
// llegan como uniforms globales que el agujero actualiza cada frame, de modo
// que TODOS los materiales del piso (asfalto, vereda, línea, pasto, base)
// comparten el mismo recorte sin tener que sincronizar nada a mano.

global uniform vec3 hole_position;
global uniform float hole_radius;

uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float rim_darkness : hint_range(0.0, 1.0) = 0.72;
uniform float rim_width : hint_range(0.0, 2.0) = 0.32;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float d = distance(world_pos.xz, hole_position.xz);
	if (d < hole_radius) {
		discard;
	}
	// Sombra de borde: el piso se va oscureciendo al acercarse a la boca.
	// Sin esto el corte queda como recortado con tijera y se pierde el volumen.
	float rim = 1.0 - smoothstep(hole_radius, hole_radius * (1.0 + rim_width) + 0.4, d);
	ALBEDO = base_color.rgb * (1.0 - rim_darkness * rim * rim);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
