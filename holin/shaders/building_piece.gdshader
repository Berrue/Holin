shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

// Un pedazo de edificio. Dibuja el modelo ENTERO y descarta lo que cae fuera de
// una franja de altura, así cada pedazo conserva la fachada real —las ventanas,
// el remate, la marquesina— en vez de ser un cubo genérico de escombro. Cortar
// la malla de verdad en runtime costaría generar geometría nueva; esto es un if.
//
// La franja va en coordenadas LOCALES de la malla (VERTEX.y), que no dependen de
// cuánto se haya escalado el modelo al plantarlo en la ciudad.

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform float y_min = -1000.0;
uniform float y_max = 1000.0;

varying float local_y;

void vertex() {
	local_y = VERTEX.y;
}

void fragment() {
	if (local_y < y_min || local_y > y_max) {
		discard;
	}
	vec3 c = texture(albedo_tex, UV).rgb;
	// El corte deja el modelo hueco. Sin cull_disabled se vería directamente a
	// través del pedazo; con él se ve la cara interna de la pared del fondo, y
	// oscurecerla la hace leer como interior en sombra y no como error de normales.
	if (!FRONT_FACING) {
		c *= 0.42;
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
