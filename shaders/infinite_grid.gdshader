shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Grid configuration
uniform vec4 grid_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4 secondary_grid_color : source_color = vec4(0.7, 0.7, 0.7, 1.0);
uniform float primary_line_width : hint_range(0.001, 0.1) = 0.02;
uniform float secondary_line_width : hint_range(0.001, 0.05) = 0.01;
uniform float primary_grid_size : hint_range(0.1, 10.0) = 1.0;
uniform float secondary_grid_scale : hint_range(2.0, 20.0) = 10.0;

// Fade configuration
uniform float fade_start : hint_range(1.0, 100.0) = 20.0;
uniform float fade_end : hint_range(10.0, 200.0) = 50.0;

varying vec3 world_pos;
varying float camera_dist;

void vertex() {
	// Get world position for grid calculation
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Calculate distance from camera for fade
	vec3 camera_pos = (inverse(VIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	camera_dist = length(world_pos.xz - camera_pos.xz);
}

float get_grid_line(vec2 coord, float grid_size, float line_width) {
	// Calculate grid coordinates
	vec2 grid = abs(fract(coord / grid_size - 0.5) - 0.5) * grid_size;

	// Calculate line intensity using screen-space derivatives for anti-aliasing
	vec2 grid_deriv = fwidth(coord);
	float line_width_scaled = line_width * 0.5;

	// Smooth line with anti-aliasing
	vec2 line = smoothstep(line_width_scaled + grid_deriv, line_width_scaled - grid_deriv, grid);

	return clamp(line.x + line.y, 0.0, 1.0);
}

void fragment() {
	// Calculate fade factor based on distance
	float fade = 1.0 - smoothstep(fade_start, fade_end, camera_dist);

	// Early discard for performance when fully faded
	if (fade <= 0.001) {
		discard;
	}

	// Get world XZ coordinates for grid
	vec2 coord = world_pos.xz;

	// Calculate secondary (larger) grid
	float secondary_size = primary_grid_size * secondary_grid_scale;
	float secondary_line = get_grid_line(coord, secondary_size, secondary_line_width * secondary_grid_scale);

	// Calculate primary grid
	float primary_line = get_grid_line(coord, primary_grid_size, primary_line_width);

	// Combine grids - secondary takes priority
	vec3 final_color = vec3(0.0);
	float final_alpha = 0.0;

	if (secondary_line > 0.0) {
		final_color = secondary_grid_color.rgb;
		final_alpha = secondary_line * secondary_grid_color.a;
	}

	if (primary_line > 0.0 && primary_line > secondary_line) {
		final_color = mix(final_color, grid_color.rgb, primary_line);
		final_alpha = max(final_alpha, primary_line * grid_color.a);
	}

	// Apply distance fade
	final_alpha *= fade;

	// Discard fully transparent pixels for performance
	if (final_alpha <= 0.001) {
		discard;
	}

	ALBEDO = final_color;
	ALPHA = final_alpha;
}
