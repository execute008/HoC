shader_type sky;

// Sky colors
uniform vec3 horizon_color : source_color = vec3(0.02, 0.02, 0.05);
uniform vec3 zenith_color : source_color = vec3(0.0, 0.0, 0.02);
uniform vec3 nadir_color : source_color = vec3(0.01, 0.01, 0.02);

// Star configuration
uniform float star_density : hint_range(0.0, 1.0) = 0.5;
uniform float star_brightness : hint_range(0.0, 2.0) = 1.0;
uniform float star_twinkle_speed : hint_range(0.0, 5.0) = 1.5;

// Nebula configuration
uniform vec3 nebula_color_1 : source_color = vec3(0.1, 0.02, 0.15);
uniform vec3 nebula_color_2 : source_color = vec3(0.02, 0.05, 0.12);
uniform float nebula_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float nebula_scale : hint_range(0.5, 5.0) = 2.0;

// Hash function for pseudo-random numbers
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// 3D noise for nebula
float noise3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n = mix(
		mix(
			mix(hash3(i), hash3(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(hash3(i + vec3(0.0, 1.0, 0.0)), hash3(i + vec3(1.0, 1.0, 0.0)), f.x),
			f.y
		),
		mix(
			mix(hash3(i + vec3(0.0, 0.0, 1.0)), hash3(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(hash3(i + vec3(0.0, 1.0, 1.0)), hash3(i + vec3(1.0, 1.0, 1.0)), f.x),
			f.y
		),
		f.z
	);
	return n;
}

// Fractal brownian motion for nebula
float fbm(vec3 p) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;

	for (int i = 0; i < 5; i++) {
		value += amplitude * noise3d(p * frequency);
		amplitude *= 0.5;
		frequency *= 2.0;
	}
	return value;
}

// Star field generation
float stars(vec3 dir, float time) {
	// Create a grid in spherical space
	float theta = atan(dir.z, dir.x);
	float phi = asin(clamp(dir.y, -1.0, 1.0));

	vec2 uv = vec2(theta / TAU + 0.5, phi / PI + 0.5);
	vec2 grid_uv = uv * 200.0; // Star grid density
	vec2 cell = floor(grid_uv);
	vec2 local = fract(grid_uv) - 0.5;

	float star = 0.0;

	// Check neighboring cells for stars
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 offset = vec2(float(x), float(y));
			vec2 cell_pos = cell + offset;

			// Random position within cell
			float h = hash(cell_pos);
			if (h > (1.0 - star_density * 0.1)) {
				vec2 star_pos = vec2(hash(cell_pos + 0.1), hash(cell_pos + 0.2)) - 0.5;
				vec2 diff = local - offset - star_pos;
				float dist = length(diff);

				// Star brightness with twinkle
				float brightness = hash(cell_pos + 0.3);
				float twinkle = sin(time * star_twinkle_speed * (brightness * 2.0 + 1.0) + brightness * TAU) * 0.3 + 0.7;

				// Star glow falloff
				float glow = exp(-dist * 30.0) * brightness * twinkle;
				star += glow;
			}
		}
	}

	return star * star_brightness;
}

// Nebula generation
vec3 nebula(vec3 dir) {
	vec3 scaled_dir = dir * nebula_scale;

	// Two layers of nebula with different colors
	float n1 = fbm(scaled_dir + vec3(0.0, 0.0, 0.0));
	float n2 = fbm(scaled_dir + vec3(5.0, 3.0, 7.0));

	// Shape the nebula - make it wispy
	n1 = pow(n1, 2.0) * smoothstep(0.3, 0.7, n1);
	n2 = pow(n2, 2.0) * smoothstep(0.3, 0.7, n2);

	vec3 nebula_result = nebula_color_1 * n1 + nebula_color_2 * n2;
	return nebula_result * nebula_intensity;
}

void sky() {
	vec3 dir = EYEDIR;

	// Base sky gradient
	float up = dir.y;
	vec3 sky_color;

	if (up >= 0.0) {
		// Above horizon - blend to zenith
		sky_color = mix(horizon_color, zenith_color, pow(up, 0.5));
	} else {
		// Below horizon - blend to nadir
		sky_color = mix(horizon_color, nadir_color, pow(-up, 0.5));
	}

	// Add nebula
	vec3 nebula_color = nebula(dir);
	sky_color += nebula_color;

	// Add stars (slightly less visible near horizon)
	float star_mask = smoothstep(-0.1, 0.3, abs(up));
	float star_field = stars(dir, TIME);

	// Stars are white/blue-white
	vec3 star_color = mix(vec3(0.9, 0.95, 1.0), vec3(1.0, 0.9, 0.8), hash(dir.xz)) * star_field;
	sky_color += star_color * star_mask;

	COLOR = sky_color;
}
