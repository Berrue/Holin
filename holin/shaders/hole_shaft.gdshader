shader_type spatial;
render_mode cull_front, unshaded, shadows_disabled;

// Paredes internas del pozo. Se dibuja con cull_front para ver la cara de
// adentro del cilindro (mirando a un pozo se ve la pared del fondo, no la de
// adelante). El degradé vertical + las estrías verticales son lo que le da la
// lectura de profundidad: sin ellas un cilindro oscuro parece un disco plano.

// Fase del remolino. La acumula hole.gd en vez de usar TIME * velocidad: la
// velocidad del remolino sigue a la del agujero, y multiplicando TIME por un
// factor variable la fase pega saltos cada vez que ese factor cambia.
uniform float shaft_depth = 9.0;
uniform vec4 rim_color : source_color = vec4(0.40, 0.37, 0.42, 1.0);
uniform vec4 wall_color : source_color = vec4(0.14, 0.13, 0.18, 1.0);
uniform vec4 deep_color : source_color = vec4(0.01, 0.01, 0.02, 1.0);

varying vec3 local_pos;
varying float world_y;

void vertex() {
	local_pos = VERTEX;
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	float t = clamp(-world_y / shaft_depth, 0.0, 1.0);
	// Labio claro justo abajo del borde, después pared, después negro.
	vec3 c = mix(rim_color.rgb, wall_color.rgb, smoothstep(0.0, 0.08, t));
	// El apagón llega hasta bien abajo (antes se comía todo a 0.7): los objetos se
	// consumen a 6.5 de 9 m, así que con el corte anterior el último tramo de la
	// caída pasaba contra negro puro y no se veía caer nada.
	c = mix(c, deep_color.rgb, smoothstep(0.05, 0.95, t));
	// Estrías: dan referencia de curvatura y de escala al mover el agujero.
	float a = atan(local_pos.z, local_pos.x);
	c *= 0.88 + 0.12 * sin(a * 24.0);
	ALBEDO = c;
}
