/*
 * Copyright 2021 Blender Foundation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* Metal kernel entry points */

#include "kernel/device/metal/compat.h"
#include "kernel/device/metal/globals.h"
#include "kernel/device/gpu/kernel.h"

/* MetalRT intersection handlers */
#ifdef __METALRT__

/* Return type for a bounding box intersection function. */
struct BoundingBoxIntersectionResult
{
  bool accept [[accept_intersection]];
  bool continue_search [[continue_search]];
  float distance [[distance]];
};

/* Return type for a triangle intersection function. */
struct TriangleIntersectionResult
{
  bool accept [[accept_intersection]];
  bool continue_search  [[continue_search]];
};

enum { METALRT_HIT_TRIANGLE, METALRT_HIT_BOUNDING_BOX };

template<typename TReturn, uint intersection_type>
TReturn metalrt_local_hit(constant KernelParamsMetal &launch_params_metal,
                          ray_data MetalKernelContext::MetalRTIntersectionLocalPayload &payload,
                          const uint object,
                          const uint primitive_id,
                          const float2 barycentrics,
                          const float ray_tmax)
{
  TReturn result;
  
#ifdef __BVH_LOCAL__
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);

  if (object != payload.local_object) {
    /* Only intersect with matching object */
    result.accept = false;
    result.continue_search = true;
    return result;
  }

  const short max_hits = payload.max_hits;
  if (max_hits == 0) {
    /* Special case for when no hit information is requested, just report that something was hit */
    payload.result = true;
    result.accept = true;
    result.continue_search = false;
    return result;
  }

  int hit = 0;
  if (payload.has_lcg_state) {
    for (short i = min(max_hits, short(payload.local_isect.num_hits)) - 1; i >= 0; --i) {
      if (ray_tmax == payload.local_isect.hits[i].t) {
        result.accept = false;
        result.continue_search = true;
        return result;
      }
    }

    hit = payload.local_isect.num_hits++;

    if (payload.local_isect.num_hits > max_hits) {
      hit = lcg_step_uint(&payload.lcg_state) % payload.local_isect.num_hits;
      if (hit >= max_hits) {
        result.accept = false;
        result.continue_search = true;
        return result;
      }
    }
  }
  else {
    if (payload.local_isect.num_hits && ray_tmax > payload.local_isect.hits[0].t) {
      /* Record closest intersection only. Do not terminate ray here, since there is no guarantee about distance ordering in any-hit */
      result.accept = false;
      result.continue_search = true;
      return result;
    }

    payload.local_isect.num_hits = 1;
  }

  ray_data Intersection *isect = &payload.local_isect.hits[hit];
  isect->t = ray_tmax;
  isect->prim = prim;
  isect->object = object;
  isect->type = kernel_tex_fetch(__objects, object).primitive_type;

  isect->u = 1.0f - barycentrics.y - barycentrics.x;
  isect->v = barycentrics.x;

  /* Record geometric normal */
  const uint tri_vindex = kernel_tex_fetch(__tri_vindex, isect->prim).w;
  const float3 tri_a = float3(kernel_tex_fetch(__tri_verts, tri_vindex + 0));
  const float3 tri_b = float3(kernel_tex_fetch(__tri_verts, tri_vindex + 1));
  const float3 tri_c = float3(kernel_tex_fetch(__tri_verts, tri_vindex + 2));
  payload.local_isect.Ng[hit] = normalize(cross(tri_b - tri_a, tri_c - tri_a));

  /* Continue tracing (without this the trace call would return after the first hit) */
  result.accept = false;
  result.continue_search = true;
  return result;
#endif
}

[[intersection(triangle, triangle_data, METALRT_TAGS)]]
TriangleIntersectionResult
__anyhit__cycles_metalrt_local_hit_tri(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                                       ray_data MetalKernelContext::MetalRTIntersectionLocalPayload &payload [[payload]],
                                       uint instance_id [[user_instance_id]],
                                       uint primitive_id [[primitive_id]],
                                       float2 barycentrics [[barycentric_coord]],
                                       float ray_tmax [[distance]])
{
  return metalrt_local_hit<TriangleIntersectionResult, METALRT_HIT_TRIANGLE>(
            launch_params_metal, payload, instance_id, primitive_id, barycentrics, ray_tmax);
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__anyhit__cycles_metalrt_local_hit_box(const float ray_tmax [[max_distance]])
{
  /* unused function */
  BoundingBoxIntersectionResult result;
  result.distance = ray_tmax;
  result.accept = false;
  result.continue_search = false;
  return result;
}

template<uint intersection_type>
bool metalrt_shadow_all_hit(constant KernelParamsMetal &launch_params_metal,
                            ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload,
                            uint object,
                            uint prim,
                            const float2 barycentrics,
                            const float ray_tmax)
{
#ifdef __SHADOW_RECORD_ALL__
#  ifdef __VISIBILITY_FLAG__
  const uint visibility = payload.visibility;
  if ((kernel_tex_fetch(__objects, object).visibility & visibility) == 0) {
    /* continue search */
    return true;
  }
#  endif

  float u = 0.0f, v = 0.0f;
  int type = 0;
  if (intersection_type == METALRT_HIT_TRIANGLE) {
    u = 1.0f - barycentrics.y - barycentrics.x;
    v = barycentrics.x;
    type = kernel_tex_fetch(__objects, object).primitive_type;
  }
#  ifdef __HAIR__
  else {
    u = barycentrics.x;
    v = barycentrics.y;
    
    const KernelCurveSegment segment = kernel_tex_fetch(__curve_segments, prim);
    type = segment.type;
    prim = segment.prim;

    /* Filter out curve endcaps */
    if (u == 0.0f || u == 1.0f) {
      /* continue search */
      return true;
    }
  }
#  endif

#  ifndef __TRANSPARENT_SHADOWS__
  /* No transparent shadows support compiled in, make opaque. */
  payload.result = true;
  /* terminate ray */
  return false;
#  else
  short max_hits = payload.max_hits;
  short num_hits = payload.num_hits;
  short num_recorded_hits = payload.num_recorded_hits;

  MetalKernelContext context(launch_params_metal);
  
  /* If no transparent shadows, all light is blocked and we can stop immediately. */
  if (num_hits >= max_hits ||
      !(context.intersection_get_shader_flags(NULL, prim, type) & SD_HAS_TRANSPARENT_SHADOW)) {
    payload.result = true;
    /* terminate ray */
    return false;
  }
  
  /* Always use baked shadow transparency for curves. */
  if (type & PRIMITIVE_CURVE) {
    float throughput = payload.throughput;
    throughput *= context.intersection_curve_shadow_transparency(nullptr, object, prim, u);
    payload.throughput = throughput;
    payload.num_hits += 1;

    if (throughput < CURVE_SHADOW_TRANSPARENCY_CUTOFF) {
      /* Accept result and terminate if throughput is sufficiently low */
      payload.result = true;
      return false;
    }
    else {
      return true;
    }
  }
  
  payload.num_hits += 1;
  payload.num_recorded_hits += 1;
  
  uint record_index = num_recorded_hits;

  const IntegratorShadowState state = payload.state;

  const uint max_record_hits = min(uint(max_hits), INTEGRATOR_SHADOW_ISECT_SIZE);
  if (record_index >= max_record_hits) {
    /* If maximum number of hits reached, find a hit to replace. */
    float max_recorded_t = INTEGRATOR_STATE_ARRAY(state, shadow_isect, 0, t);
    uint max_recorded_hit = 0;

    for (int i = 1; i < max_record_hits; i++) {
      const float isect_t = INTEGRATOR_STATE_ARRAY(state, shadow_isect, i, t);
      if (isect_t > max_recorded_t) {
        max_recorded_t = isect_t;
        max_recorded_hit = i;
      }
    }

    if (ray_tmax >= max_recorded_t) {
      /* Accept hit, so that we don't consider any more hits beyond the distance of the
       * current hit anymore. */
      payload.result = true;
      return true;
    }

    record_index = max_recorded_hit;
  }

  INTEGRATOR_STATE_ARRAY_WRITE(state, shadow_isect, record_index, u) = u;
  INTEGRATOR_STATE_ARRAY_WRITE(state, shadow_isect, record_index, v) = v;
  INTEGRATOR_STATE_ARRAY_WRITE(state, shadow_isect, record_index, t) = ray_tmax;
  INTEGRATOR_STATE_ARRAY_WRITE(state, shadow_isect, record_index, prim) = prim;
  INTEGRATOR_STATE_ARRAY_WRITE(state, shadow_isect, record_index, object) = object;
  INTEGRATOR_STATE_ARRAY_WRITE(state, shadow_isect, record_index, type) = type;
  
  /* Continue tracing. */
#  endif /* __TRANSPARENT_SHADOWS__ */
#endif   /* __SHADOW_RECORD_ALL__ */

  return true;
}

[[intersection(triangle, triangle_data, METALRT_TAGS)]]
TriangleIntersectionResult
__anyhit__cycles_metalrt_shadow_all_hit_tri(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                                            ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload [[payload]],
                                            unsigned int object [[user_instance_id]],
                                            unsigned int primitive_id [[primitive_id]],
                                            float2 barycentrics [[barycentric_coord]],
                                            float ray_tmax [[distance]])
{
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);

  TriangleIntersectionResult result;
  result.continue_search = metalrt_shadow_all_hit<METALRT_HIT_TRIANGLE>(
            launch_params_metal, payload, object, prim, barycentrics, ray_tmax);
  result.accept = !result.continue_search;
  return result;
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__anyhit__cycles_metalrt_shadow_all_hit_box(const float ray_tmax [[max_distance]])
{
  /* unused function */
  BoundingBoxIntersectionResult result;
  result.distance = ray_tmax;
  result.accept = false;
  result.continue_search = false;
  return result;
}

template<typename TReturnType, uint intersection_type>
inline TReturnType metalrt_visibility_test(constant KernelParamsMetal &launch_params_metal,
                                           ray_data MetalKernelContext::MetalRTIntersectionPayload &payload,
                                           const uint object,
                                           const uint prim,
                                           const float u)
{
  TReturnType result;
    
#  ifdef __HAIR__
  if (intersection_type == METALRT_HIT_BOUNDING_BOX) {
    /* Filter out curve endcaps. */
    if (u == 0.0f || u == 1.0f) {
      result.accept = false;
      result.continue_search = true;
      return result;
    }
  }
#  endif

#  ifdef __VISIBILITY_FLAG__
  uint visibility = payload.visibility;
  if ((kernel_tex_fetch(__objects, object).visibility & visibility) == 0) {
    result.accept = false;
    result.continue_search = true;
    return result;
  }

  /* Shadow ray early termination. */
  if (visibility & PATH_RAY_SHADOW_OPAQUE) {
    result.accept = true;
    result.continue_search = false;
    return result;
  }
#  endif

  result.accept = true;
  result.continue_search = true;
  return result;
}

[[intersection(triangle, triangle_data, METALRT_TAGS)]]
TriangleIntersectionResult
__anyhit__cycles_metalrt_visibility_test_tri(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                                             ray_data MetalKernelContext::MetalRTIntersectionPayload &payload [[payload]],
                                             unsigned int object [[user_instance_id]],
                                             unsigned int primitive_id [[primitive_id]])
{
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  TriangleIntersectionResult result = metalrt_visibility_test<TriangleIntersectionResult, METALRT_HIT_TRIANGLE>(
            launch_params_metal, payload, object, prim, 0.0f);
  if (result.accept) {
    payload.prim = prim;
    payload.type = kernel_tex_fetch(__objects, object).primitive_type;
  }
  return result;
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__anyhit__cycles_metalrt_visibility_test_box(const float ray_tmax [[max_distance]])
{
  /* Unused function */
  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;
  return result;
}

#ifdef __HAIR__
ccl_device_inline
void metalrt_intersection_curve(constant KernelParamsMetal &launch_params_metal,
                                ray_data MetalKernelContext::MetalRTIntersectionPayload &payload,
                                const uint object,
                                const uint prim,
                                const uint type,
                                const float3 ray_origin,
                                const float3 ray_direction,
                                float time,
                                const float ray_tmax,
                                thread BoundingBoxIntersectionResult &result)
{
#  ifdef __VISIBILITY_FLAG__
  const uint visibility = payload.visibility;
  if ((kernel_tex_fetch(__objects, object).visibility & visibility) == 0) {
    return;
  }
#  endif

  float3 P = ray_origin;
  float3 dir = ray_direction;

  /* The direction is not normalized by default, but the curve intersection routine expects that */
  float len;
  dir = normalize_len(dir, &len);

  Intersection isect;
  isect.t = ray_tmax;
  /* Transform maximum distance into object space. */
  if (isect.t != FLT_MAX)
    isect.t *= len;

  MetalKernelContext context(launch_params_metal);
  if (context.curve_intersect(NULL, &isect, P, dir, isect.t, object, prim, time, type)) {
    result = metalrt_visibility_test<BoundingBoxIntersectionResult, METALRT_HIT_BOUNDING_BOX>(
                  launch_params_metal, payload, object, prim, isect.u);
    if (result.accept) {
      result.distance = isect.t / len;
      payload.u = isect.u;
      payload.v = isect.v;
      payload.prim = prim;
      payload.type = type;
    }
  }
}

ccl_device_inline
void metalrt_intersection_curve_shadow(constant KernelParamsMetal &launch_params_metal,
                                       ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload,
                                       const uint object,
                                       const uint prim,
                                       const uint type,
                                       const float3 ray_origin,
                                       const float3 ray_direction,
                                       float time,
                                       const float ray_tmax,
                                       thread BoundingBoxIntersectionResult &result)
{
  const uint visibility = payload.visibility;

  float3 P = ray_origin;
  float3 dir = ray_direction;

  /* The direction is not normalized by default, but the curve intersection routine expects that */
  float len;
  dir = normalize_len(dir, &len);

  Intersection isect;
  isect.t = ray_tmax;
  /* Transform maximum distance into object space */
  if (isect.t != FLT_MAX)
    isect.t *= len;

  MetalKernelContext context(launch_params_metal);
  if (context.curve_intersect(NULL, &isect, P, dir, isect.t, object, prim, time, type)) {
    result.continue_search = metalrt_shadow_all_hit<METALRT_HIT_BOUNDING_BOX>(
                launch_params_metal, payload, object, prim, float2(isect.u, isect.v), ray_tmax);
    result.accept = !result.continue_search;

    if (result.accept) {
      result.distance = isect.t / len;
    }
  }
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__intersection__curve_ribbon(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                             ray_data MetalKernelContext::MetalRTIntersectionPayload &payload [[payload]],
                             const uint object [[user_instance_id]],
                             const uint primitive_id [[primitive_id]],
                             const float3 ray_origin [[origin]],
                             const float3 ray_direction [[direction]],
                             const float ray_tmax [[max_distance]])
{
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  const KernelCurveSegment segment = kernel_tex_fetch(__curve_segments, prim);

  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;

  if (segment.type & PRIMITIVE_CURVE_RIBBON) {
    metalrt_intersection_curve(launch_params_metal, payload, object, segment.prim, segment.type, ray_origin, ray_direction,
#  if defined(__METALRT_MOTION__)
                               payload.time,
#  else
                               0.0f,
#  endif
                               ray_tmax, result);
  }

  return result;
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__intersection__curve_ribbon_shadow(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                                    ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload [[payload]],
                                    const uint object [[user_instance_id]],
                                    const uint primitive_id [[primitive_id]],
                                    const float3 ray_origin [[origin]],
                                    const float3 ray_direction [[direction]],
                                    const float ray_tmax [[max_distance]])
{
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  const KernelCurveSegment segment = kernel_tex_fetch(__curve_segments, prim);

  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;

  if (segment.type & PRIMITIVE_CURVE_RIBBON) {
    metalrt_intersection_curve_shadow(launch_params_metal, payload, object, segment.prim, segment.type, ray_origin, ray_direction,
#  if defined(__METALRT_MOTION__)
                               payload.time,
#  else
                               0.0f,
#  endif
                               ray_tmax, result);
  }

  return result;
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__intersection__curve_all(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                          ray_data MetalKernelContext::MetalRTIntersectionPayload &payload [[payload]],
                          const uint object [[user_instance_id]],
                          const uint primitive_id [[primitive_id]],
                          const float3 ray_origin [[origin]],
                          const float3 ray_direction [[direction]],
                          const float ray_tmax [[max_distance]])
{
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  const KernelCurveSegment segment = kernel_tex_fetch(__curve_segments, prim);
    
  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;
  metalrt_intersection_curve(launch_params_metal, payload, object, segment.prim, segment.type, ray_origin, ray_direction,
#  if defined(__METALRT_MOTION__)
                             payload.time,
#  else
                             0.0f,
#  endif
                             ray_tmax, result);

  return result;
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__intersection__curve_all_shadow(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                                 ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload [[payload]],
                                 const uint object [[user_instance_id]],
                                 const uint primitive_id [[primitive_id]],
                                 const float3 ray_origin [[origin]],
                                 const float3 ray_direction [[direction]],
                                 const float ray_tmax [[max_distance]])
{
  uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  const KernelCurveSegment segment = kernel_tex_fetch(__curve_segments, prim);

  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;

  metalrt_intersection_curve_shadow(launch_params_metal, payload, object, segment.prim, segment.type, ray_origin, ray_direction,
#  if defined(__METALRT_MOTION__)
                             payload.time,
#  else
                             0.0f,
#  endif
                             ray_tmax, result);

  return result;
}
#endif /* __HAIR__ */

#ifdef __POINTCLOUD__
ccl_device_inline
void metalrt_intersection_point(constant KernelParamsMetal &launch_params_metal,
                                ray_data MetalKernelContext::MetalRTIntersectionPayload &payload,
                                const uint object,
                                const uint prim,
                                const uint type,
                                const float3 ray_origin,
                                const float3 ray_direction,
                                float time,
                                const float ray_tmax,
                                thread BoundingBoxIntersectionResult &result)
{
#  ifdef __VISIBILITY_FLAG__
  const uint visibility = payload.visibility;
  if ((kernel_tex_fetch(__objects, object).visibility & visibility) == 0) {
    return;
  }
#  endif

  float3 P = ray_origin;
  float3 dir = ray_direction;

  /* The direction is not normalized by default, but the point intersection routine expects that */
  float len;
  dir = normalize_len(dir, &len);

  Intersection isect;
  isect.t = ray_tmax;
  /* Transform maximum distance into object space. */
  if (isect.t != FLT_MAX)
    isect.t *= len;

  MetalKernelContext context(launch_params_metal);
  if (context.point_intersect(NULL, &isect, P, dir, isect.t, object, prim, time, type)) {
    result = metalrt_visibility_test<BoundingBoxIntersectionResult, METALRT_HIT_BOUNDING_BOX>(
                  launch_params_metal, payload, object, prim, isect.u);
    if (result.accept) {
      result.distance = isect.t / len;
      payload.u = isect.u;
      payload.v = isect.v;
      payload.prim = prim;
      payload.type = type;
    }
  }
}

ccl_device_inline
void metalrt_intersection_point_shadow(constant KernelParamsMetal &launch_params_metal,
                                       ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload,
                                       const uint object,
                                       const uint prim,
                                       const uint type,
                                       const float3 ray_origin,
                                       const float3 ray_direction,
                                       float time,
                                       const float ray_tmax,
                                       thread BoundingBoxIntersectionResult &result)
{
  const uint visibility = payload.visibility;

  float3 P = ray_origin;
  float3 dir = ray_direction;

  /* The direction is not normalized by default, but the point intersection routine expects that */
  float len;
  dir = normalize_len(dir, &len);

  Intersection isect;
  isect.t = ray_tmax;
  /* Transform maximum distance into object space */
  if (isect.t != FLT_MAX)
    isect.t *= len;

  MetalKernelContext context(launch_params_metal);
  if (context.point_intersect(NULL, &isect, P, dir, isect.t, object, prim, time, type)) {
    result.continue_search = metalrt_shadow_all_hit<METALRT_HIT_BOUNDING_BOX>(
                launch_params_metal, payload, object, prim, float2(isect.u, isect.v), ray_tmax);
    result.accept = !result.continue_search;

    if (result.accept) {
      result.distance = isect.t / len;
    }
  }
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__intersection__point(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                             ray_data MetalKernelContext::MetalRTIntersectionPayload &payload [[payload]],
                             const uint object [[user_instance_id]],
                             const uint primitive_id [[primitive_id]],
                             const float3 ray_origin [[origin]],
                             const float3 ray_direction [[direction]],
                             const float ray_tmax [[max_distance]])
{
  const uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  const int type = kernel_tex_fetch(__objects, object).primitive_type;

  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;

  metalrt_intersection_point(launch_params_metal, payload, object, prim, type, ray_origin, ray_direction,
#  if defined(__METALRT_MOTION__)
                             payload.time,
#  else
                             0.0f,
#  endif
                             ray_tmax, result);

  return result;
}

[[intersection(bounding_box, triangle_data, METALRT_TAGS)]]
BoundingBoxIntersectionResult
__intersection__point_shadow(constant KernelParamsMetal &launch_params_metal [[buffer(1)]],
                                    ray_data MetalKernelContext::MetalRTIntersectionShadowPayload &payload [[payload]],
                                    const uint object [[user_instance_id]],
                                    const uint primitive_id [[primitive_id]],
                                    const float3 ray_origin [[origin]],
                                    const float3 ray_direction [[direction]],
                                    const float ray_tmax [[max_distance]])
{
  const uint prim = primitive_id + kernel_tex_fetch(__object_prim_offset, object);
  const int type = kernel_tex_fetch(__objects, object).primitive_type;

  BoundingBoxIntersectionResult result;
  result.accept = false;
  result.continue_search = true;
  result.distance = ray_tmax;

  metalrt_intersection_point_shadow(launch_params_metal, payload, object, prim, type, ray_origin, ray_direction,
#  if defined(__METALRT_MOTION__)
                             payload.time,
#  else
                             0.0f,
#  endif
                             ray_tmax, result);

  return result;
}
#endif /* __POINTCLOUD__ */
#endif /* __METALRT__ */
