
#pragma BLENDER_REQUIRE(common_view_lib.glsl)
#pragma BLENDER_REQUIRE(workbench_shader_interface_lib.glsl)
#pragma BLENDER_REQUIRE(workbench_common_lib.glsl)
#pragma BLENDER_REQUIRE(workbench_material_lib.glsl)
#pragma BLENDER_REQUIRE(workbench_image_lib.glsl)

#ifndef WORKBENCH_SHADER_SHARED_H
in vec3 pos;
in vec3 nor;
in vec4 ac; /* active color */
in vec2 au; /* active texture layer */
#endif

void main()
{
  vec3 world_pos = point_object_to_world(pos);
  gl_Position = point_world_to_ndc(world_pos);

#ifdef USE_WORLD_CLIP_PLANES
  world_clip_planes_calc_clip_distance(world_pos);
#endif

  uv_interp = au;

  normal_interp = normalize(normal_object_to_view(nor));

#ifndef WORKBENCH_SHADER_SHARED_H
#  ifdef OPAQUE_MATERIAL
  float metallic, roughness;
#  endif
#endif
  workbench_material_data_get(resource_handle, color_interp, alpha_interp, roughness, metallic);

  if (materialIndex == 0) {
    color_interp = ac.rgb;
  }

#ifdef OPAQUE_MATERIAL
  packed_rough_metal = workbench_float_pair_encode(roughness, metallic);
#endif

  object_id = int(uint(resource_handle) & 0xFFFFu) + 1;
}
