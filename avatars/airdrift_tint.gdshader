shader_type spatial;
render_mode cull_back;

// One tintable channel per part, written per instance by GSAvatarBuilder so two
// players wearing the same part never recolour each other. Instance uniforms are
// the whole reason this is a shader and not a StandardMaterial3D.
instance uniform vec4 gs_avatar_tint_0 : source_color = vec4(0.75, 0.75, 0.78, 1.0);

void fragment() {
	ALBEDO = gs_avatar_tint_0.rgb;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
}
