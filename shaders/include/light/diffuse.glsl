#if !defined INCLUDE_LIGHT_DIFFUSE
#define INCLUDE_LIGHT_DIFFUSE

#include "/include/light/colors/blocklight_color.glsl"
#include "/include/light/colors/weather_color.glsl"
#include "/include/light/bsdf.glsl"
#include "/include/misc/material.glsl"
#include "/include/utility/phase_functions.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/spherical_harmonics.glsl"

// Add include and uniforms
#include "/include/utility/space_conversion.glsl"        
uniform int heldItemId;
uniform int heldItemId2;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

vec3 get_torchlight_color() {
	vec3 color1, color2;
	if( heldItemId == 1 ) color1 = vec3(1.0, 0.78, 0.72); // Warm
	else if( heldItemId == 2 ) color1 = vec3(0.5, 0.5, 1.00); // Cold
	else if( heldItemId == 3 ) color1 = vec3(1.0, 0.25, 0.25); // Red
	else if( heldItemId == 4 ) color1 = vec3(0.75, 1.00, 0.75); // Light Green
	else if( heldItemId == 5 ) color1 = vec3(0.25, 0.25, 1.00); // Blue
	else color1 = vec3(1.0, 0.78, 0.72); // Default

	if( heldItemId2 == 1 ) color2 = vec3(1.0, 0.78, 0.72); // Warm
	else if( heldItemId2 == 2 ) color2 = vec3(0.72, 0.78, 1.00); // Cold
	else if( heldItemId2 == 3 ) color2 = vec3(1.0, 0.1, 0.1); // Red
	else if( heldItemId2 == 4 ) color2 = vec3(0.1, 1.00, 0.1); // Light Green
	else if( heldItemId2 == 5 ) color2 = vec3(0.1, 0.1, 1.00); // Blue
	else color2 = vec3(1.0, 0.78, 0.72); // Default

	float friction = heldBlockLightValue2 /(heldBlockLightValue + heldBlockLightValue2 + 0.00001);
	return mix(color1, color2, friction);
}

const float night_vision_scale = 1.5;
const float metal_diffuse_amount = 0.25; // Scales diffuse lighting on metals, ideally this would be zero but purely specular metals don't play well with SSR

float get_blocklight_falloff(float blocklight, float skylight, float ao) {
	float falloff  = 0.3 * pow5(blocklight) + 0.12 * sqr(blocklight) + 0.11 * dampen(blocklight);          // Base falloff
	      falloff *= mix(cube(ao), 1.0, clamp01(falloff));                                                 // Stronger AO further from the light source
		  falloff *= mix(1.0, ao * dampen(abs(cos(2.0 * frameTimeCounter))) * 0.67 + 0.2, darknessFactor); // Pulsing blocklight with darkness effect
		  falloff *= 1.0 - 0.2 * time_noon * skylight - 0.2 * skylight;                                    // Reduce blocklight intensity in daylight
		  falloff += min(2.7 * pow12(blocklight), 0.9);                                                    // Strong highlight around the light source, visible even in the daylight

	return falloff;
}

//----------------------------------------------------------------------------//
#if   defined WORLD_OVERWORLD

const float sss_density = 14.0;
const float sss_scale   = 5.0 * SSS_INTENSITY;

#ifdef SHADOW_VPS
vec3 sss_approx(vec3 albedo, float sss_amount, float sheen_amount, float sss_depth, float LoV, float shadow) {
	// Transmittance-based SSS
	if (sss_amount < eps) return vec3(0.0);

	vec3 coeff = albedo * inversesqrt(dot(albedo, luminance_weights) + eps);
	     coeff = clamp01(0.75 * coeff);
	     coeff = (1.0 - coeff) * sss_density / sss_amount;

	float phase = mix(isotropic_phase, henyey_greenstein_phase(-LoV, 0.7), 0.33);

	vec3 sss = sss_scale * phase * exp2(-coeff * sss_depth) * dampen(sss_amount) * pi;

#ifdef SSS_SHEEN
	vec3 sheen = (0.8 * SSS_INTENSITY) * rcp(albedo + eps) * exp2(-1.0 * coeff * sss_depth) * henyey_greenstein_phase(-LoV, 0.5) * linear_step(-0.8, -0.2, -LoV);
	return sss + sheen * sheen_amount;
#else
	return sss;
#endif
}
#else
vec3 sss_approx(vec3 albedo, float sss_amount, float sheen_amount, float sss_depth, float LoV, float shadow) {
	// Shadow-based SSS
	float sss = 0.06 * sss_scale * pi;
	vec3 sheen = 0.8 * rcp(albedo + eps) * henyey_greenstein_phase(-LoV, 0.5) * linear_step(-0.8, -0.2, -LoV) * shadow;

	return sss + sheen * sheen_amount;
}
#endif

vec3 get_diffuse_lighting(
	Material material,
	vec3 normal,
	vec3 flat_normal,
	vec3 shadows,
	vec2 light_levels,
	float ao,
	float sss_depth,
	float shadow_distance_fade,
	float NoL,
	float NoV,
	float NoH,
	float LoV
) {
#if defined PROGRAM_COMPOSITE1
	// Small optimization, don't calculate diffuse lighting when albedo is 0 (eg water)
	if (max_of(material.albedo) < eps) return vec3(0.0);
#endif

	vec3 lighting = vec3(0.0);

	// Sunlight/moonlight

#ifdef SHADOW
	vec3 diffuse = vec3(lift(max0(NoL), 0.33 * rcp(SHADING_STRENGTH)) * (1.0 - 0.5 * material.sss_amount));
	vec3 bounced = 0.033 * (1.0 - shadows) * (1.0 - 0.1 * max0(normal.y)) * pow1d5(ao + eps) * pow4(light_levels.y) * BOUNCED_LIGHT_I;
	vec3 sss = sss_approx(material.albedo, material.sss_amount, material.sheen_amount, sss_depth, LoV, shadows.x) * linear_step(0.0, 0.1, light_levels.y);

	// Adjust SSS outside of shadow distance
	sss *= mix(1.0, ao * (clamp01(NoL) * 0.9 + 0.1), clamp01(shadow_distance_fade));

	#ifdef AO_IN_SUNLIGHT
	diffuse *= sqrt(ao) * mix(ao * ao, 1.0, NoL * NoL);
	#endif

	#ifdef SHADOW_VPS
	// Add SSS and diffuse
	lighting += light_color * (diffuse * shadows + bounced + sss);
	#else
	// Blend SSS and diffuse
	lighting += light_color * (mix(diffuse, sss, material.sss_amount) * shadows + bounced);
	#endif
#else
	// Simple shading for when shadows are disabled
	vec3 sss = 0.08 * sss_scale * pi + 0.5 * material.sheen_amount * rcp(material.albedo + eps) * henyey_greenstein_phase(-LoV, 0.5) * linear_step(-0.8, -0.2, -LoV);

	vec3 diffuse  = vec3(lift(max0(NoL), 0.5 * rcp(SHADING_STRENGTH)) * 0.6 + 0.4) * (shadows * 0.8 + 0.2);
	     diffuse  = mix(diffuse, sss, lift(material.sss_amount, 5.0));
	     diffuse *= 1.0 * (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y));
	     diffuse *= ao * pow4(light_levels.y) * (dampen(light_dir.y) * 0.5 + 0.5);

	lighting += light_color * diffuse;
#endif

	// Skylight

	float directional_lighting = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y)); // Random directional shading to make faces easier to distinguish

#if defined PROGRAM_DEFERRED3
	#ifdef SH_SKYLIGHT
	vec3 skylight = sh_evaluate_irradiance(sky_sh, normal, ao);
	#else
	vec3 horizon_color = mix(sky_samples[1], sky_samples[2], dot(normal.xz, moon_dir.xz) * 0.5 + 0.5);
	     horizon_color = mix(horizon_color, mix(sky_samples[1], sky_samples[2], step(sun_dir.y, 0.5)), abs(normal.y) * (time_noon + time_midnight));

	float horizon_weight = 0.166 * (time_noon + time_midnight) + 0.03 * (time_sunrise + time_sunset);

	vec3 rain_skylight  = get_weather_color() * mix(sqr(directional_lighting), 0.95, step(eps, material.sss_amount));
	     rain_skylight *= mix(4.0, 2.0, smoothstep(-0.1, 0.5, sun_dir.y));

	vec3 skylight  = mix(sky_samples[0] * 1.3, horizon_color, horizon_weight);
	     skylight  = mix(horizon_color * 0.2, skylight, clamp01(abs(normal.y)) * 0.3 + 0.7);
	     skylight *= 1.0 - 0.75 * clamp01(-normal.y);
	     skylight *= 1.0 + 0.33 * clamp01(flat_normal.y) * (1.0 - shadows.x * (1.0 - rainStrength)) * (time_noon + time_midnight);
		 skylight  = mix(skylight, rain_skylight, rainStrength);
		 skylight *= ao * pi;
	#endif
#else
	vec3 skylight  = ambient_color * ao;
#endif

	float skylight_falloff = sqr(light_levels.y);

	lighting += skylight * skylight_falloff;

	// Blocklight

	float blocklight_falloff = get_blocklight_falloff(light_levels.x, light_levels.y, ao);

	lighting += (blocklight_falloff * directional_lighting) * (blocklight_scale * blocklight_color);

	lighting += material.emission * emission_scale;

	// Cave lighting

	lighting += 0.1 * CAVE_LIGHTING_I * directional_lighting * ao * (1.0 - skylight_falloff) * (1.0 - 0.7 * darknessFactor);
	lighting += nightVision * night_vision_scale * directional_lighting * ao;

#if HELD_LIGHTING >= 1
	// Held Torchlight 
	if (heldBlockLightValue > 0 || heldBlockLightValue2 > 0 ) {

		ivec2 view_texel = ivec2(gl_FragCoord.xy * taau_render_scale * rcp(taau_render_scale));
		float depth0        = texelFetch(depthtex1, view_texel, 0).x;

		vec3 view_pos  = screen_to_view_space(vec3(uv, depth0), true);
		vec3 scene_pos = view_to_scene_space(view_pos);
		vec3 world_pos = scene_pos + cameraPosition;

		float world_length = pow(length(view_pos), 0.5);

		float intensity = 0.066667 * max(heldBlockLightValue, heldBlockLightValue2); // Max Light Level is 15
		intensity *= (0.25 * HELD_LIGHTING);
		float strengh = max(0.0, pow((4 - world_length) * intensity, 2.2));

		lighting += strengh * get_torchlight_color();
	}
#endif

	return max0(lighting) * material.albedo * rcp_pi * mix(1.0, metal_diffuse_amount, float(material.is_metal));
}

//----------------------------------------------------------------------------//
#elif defined WORLD_NETHER

vec3 get_diffuse_lighting(
	Material material,
	vec3 normal,
	vec3 flat_normal,
	vec3 shadows,
	vec2 light_levels,
	float ao,
	float sss_depth,
	float shadow_distance_fade,
	float NoL,
	float NoV,
	float NoH,
	float LoV
) {
#if defined PROGRAM_COMPOSITE1
	// Small optimization, don't calculate diffuse lighting when albedo is 0 (eg water)
	if (max_of(material.albedo) < eps) return vec3(0.0);
#endif

	float directional_lighting = (0.9 + 0.1 * normal.x) * (0.8 + 0.2 * abs(flat_normal.y)); // Random directional shading to make faces easier to distinguish

	vec3 lighting = 16.0 * directional_lighting * ao * mix(ambient_color, vec3(dot(ambient_color, luminance_weights_rec2020)), 0.5);

	// Blocklight

	float blocklight_falloff = get_blocklight_falloff(light_levels.x, 0.0, ao);

	lighting += (blocklight_falloff * directional_lighting) * (blocklight_scale * blocklight_color);

	lighting += material.emission * emission_scale;

#if HELD_LIGHTING >= 1
	// Held Torchlight 
	if (heldBlockLightValue > 0 || heldBlockLightValue2 > 0 ) {

		ivec2 view_texel = ivec2(gl_FragCoord.xy * taau_render_scale * rcp(taau_render_scale));
		float depth0        = texelFetch(depthtex1, view_texel, 0).x;

		vec3 view_pos  = screen_to_view_space(vec3(uv, depth0), true);
		vec3 scene_pos = view_to_scene_space(view_pos);
		vec3 world_pos = scene_pos + cameraPosition;

		float world_length = pow(length(view_pos), 0.5);

		float intensity = 0.066667 * max(heldBlockLightValue, heldBlockLightValue2); // Max Light Level is 15
		intensity *= (0.25 * HELD_LIGHTING);
		float strengh = max(0.0, pow((4 - world_length) * intensity, 2.2));

		lighting += strengh * get_torchlight_color();
	}
#endif

	return max0(lighting) * material.albedo * rcp_pi * mix(1.0, metal_diffuse_amount, float(material.is_metal));
}

//----------------------------------------------------------------------------//
#elif defined WORLD_END

#endif

#endif // INCLUDE_LIGHT_DIFFUSE
