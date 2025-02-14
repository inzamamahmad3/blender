/*
 * Adapted from code Copyright 2009-2010 NVIDIA Corporation,
 * and code copyright 2009-2012 Intel Corporation
 *
 * Modifications Copyright 2011-2014, Blender Foundation.
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

#if BVH_FEATURE(BVH_HAIR)
#  define NODE_INTERSECT bvh_node_intersect
#else
#  define NODE_INTERSECT bvh_aligned_node_intersect
#endif

/* This is a template BVH traversal function for volumes, where
 * various features can be enabled/disabled. This way we can compile optimized
 * versions for each case without new features slowing things down.
 *
 * BVH_MOTION: motion blur rendering
 */

#ifndef __KERNEL_GPU__
ccl_device
#else
ccl_device_inline
#endif
    uint BVH_FUNCTION_FULL_NAME(BVH)(KernelGlobals kg,
                                     ccl_private const Ray *ray,
                                     Intersection *isect_array,
                                     const uint max_hits,
                                     const uint visibility)
{
  /* todo:
   * - test if pushing distance on the stack helps (for non shadow rays)
   * - separate version for shadow rays
   * - likely and unlikely for if() statements
   * - test restrict attribute for pointers
   */

  /* traversal stack in CUDA thread-local memory */
  int traversal_stack[BVH_STACK_SIZE];
  traversal_stack[0] = ENTRYPOINT_SENTINEL;

  /* traversal variables in registers */
  int stack_ptr = 0;
  int node_addr = kernel_data.bvh.root;

  /* ray parameters in registers */
  const float tmax = ray->t;
  float3 P = ray->P;
  float3 dir = bvh_clamp_direction(ray->D);
  float3 idir = bvh_inverse_direction(dir);
  int object = OBJECT_NONE;
  float isect_t = tmax;

#if BVH_FEATURE(BVH_MOTION)
  Transform ob_itfm;
#endif

  int num_hits_in_instance = 0;

  uint num_hits = 0;
  isect_array->t = tmax;

  /* traversal loop */
  do {
    do {
      /* traverse internal nodes */
      while (node_addr >= 0 && node_addr != ENTRYPOINT_SENTINEL) {
        int node_addr_child1, traverse_mask;
        float dist[2];
        float4 cnodes = kernel_tex_fetch(__bvh_nodes, node_addr + 0);

        traverse_mask = NODE_INTERSECT(kg,
                                       P,
#if BVH_FEATURE(BVH_HAIR)
                                       dir,
#endif
                                       idir,
                                       isect_t,
                                       node_addr,
                                       visibility,
                                       dist);

        node_addr = __float_as_int(cnodes.z);
        node_addr_child1 = __float_as_int(cnodes.w);

        if (traverse_mask == 3) {
          /* Both children were intersected, push the farther one. */
          bool is_closest_child1 = (dist[1] < dist[0]);
          if (is_closest_child1) {
            int tmp = node_addr;
            node_addr = node_addr_child1;
            node_addr_child1 = tmp;
          }

          ++stack_ptr;
          kernel_assert(stack_ptr < BVH_STACK_SIZE);
          traversal_stack[stack_ptr] = node_addr_child1;
        }
        else {
          /* One child was intersected. */
          if (traverse_mask == 2) {
            node_addr = node_addr_child1;
          }
          else if (traverse_mask == 0) {
            /* Neither child was intersected. */
            node_addr = traversal_stack[stack_ptr];
            --stack_ptr;
          }
        }
      }

      /* if node is leaf, fetch triangle list */
      if (node_addr < 0) {
        float4 leaf = kernel_tex_fetch(__bvh_leaf_nodes, (-node_addr - 1));
        int prim_addr = __float_as_int(leaf.x);

        if (prim_addr >= 0) {
          const int prim_addr2 = __float_as_int(leaf.y);
          const uint type = __float_as_int(leaf.w);
          bool hit;

          /* pop */
          node_addr = traversal_stack[stack_ptr];
          --stack_ptr;

          /* primitive intersection */
          switch (type & PRIMITIVE_ALL) {
            case PRIMITIVE_TRIANGLE: {
              /* intersect ray against primitive */
              for (; prim_addr < prim_addr2; prim_addr++) {
                kernel_assert(kernel_tex_fetch(__prim_type, prim_addr) == type);
                /* only primitives from volume object */
                const int prim_object = (object == OBJECT_NONE) ?
                                            kernel_tex_fetch(__prim_object, prim_addr) :
                                            object;
                const int prim = kernel_tex_fetch(__prim_index, prim_addr);
                int object_flag = kernel_tex_fetch(__object_flag, prim_object);
                if ((object_flag & SD_OBJECT_HAS_VOLUME) == 0) {
                  continue;
                }
                hit = triangle_intersect(
                    kg, isect_array, P, dir, isect_t, visibility, prim_object, prim, prim_addr);
                if (hit) {
                  /* Move on to next entry in intersections array. */
                  isect_array++;
                  num_hits++;
                  num_hits_in_instance++;
                  isect_array->t = isect_t;
                  if (num_hits == max_hits) {
                    if (object != OBJECT_NONE) {
#if BVH_FEATURE(BVH_MOTION)
                      float t_fac = 1.0f / len(transform_direction(&ob_itfm, dir));
#else
                      Transform itfm = object_fetch_transform(
                          kg, object, OBJECT_INVERSE_TRANSFORM);
                      float t_fac = 1.0f / len(transform_direction(&itfm, dir));
#endif
                      for (int i = 0; i < num_hits_in_instance; i++) {
                        (isect_array - i - 1)->t *= t_fac;
                      }
                    }
                    return num_hits;
                  }
                }
              }
              break;
            }
#if BVH_FEATURE(BVH_MOTION)
            case PRIMITIVE_MOTION_TRIANGLE: {
              /* intersect ray against primitive */
              for (; prim_addr < prim_addr2; prim_addr++) {
                kernel_assert(kernel_tex_fetch(__prim_type, prim_addr) == type);
                /* only primitives from volume object */
                const int prim_object = (object == OBJECT_NONE) ?
                                            kernel_tex_fetch(__prim_object, prim_addr) :
                                            object;
                const int prim = kernel_tex_fetch(__prim_index, prim_addr);
                int object_flag = kernel_tex_fetch(__object_flag, prim_object);
                if ((object_flag & SD_OBJECT_HAS_VOLUME) == 0) {
                  continue;
                }
                hit = motion_triangle_intersect(kg,
                                                isect_array,
                                                P,
                                                dir,
                                                isect_t,
                                                ray->time,
                                                visibility,
                                                prim_object,
                                                prim,
                                                prim_addr);
                if (hit) {
                  /* Move on to next entry in intersections array. */
                  isect_array++;
                  num_hits++;
                  num_hits_in_instance++;
                  isect_array->t = isect_t;
                  if (num_hits == max_hits) {
                    if (object != OBJECT_NONE) {
#  if BVH_FEATURE(BVH_MOTION)
                      float t_fac = 1.0f / len(transform_direction(&ob_itfm, dir));
#  else
                      Transform itfm = object_fetch_transform(
                          kg, object, OBJECT_INVERSE_TRANSFORM);
                      float t_fac = 1.0f / len(transform_direction(&itfm, dir));
#  endif
                      for (int i = 0; i < num_hits_in_instance; i++) {
                        (isect_array - i - 1)->t *= t_fac;
                      }
                    }
                    return num_hits;
                  }
                }
              }
              break;
            }
#endif /* BVH_MOTION */
            default: {
              break;
            }
          }
        }
        else {
          /* instance push */
          object = kernel_tex_fetch(__prim_object, -prim_addr - 1);
          int object_flag = kernel_tex_fetch(__object_flag, object);
          if (object_flag & SD_OBJECT_HAS_VOLUME) {
#if BVH_FEATURE(BVH_MOTION)
            isect_t *= bvh_instance_motion_push(kg, object, ray, &P, &dir, &idir, &ob_itfm);
#else
            isect_t *= bvh_instance_push(kg, object, ray, &P, &dir, &idir);
#endif

            num_hits_in_instance = 0;
            isect_array->t = isect_t;

            ++stack_ptr;
            kernel_assert(stack_ptr < BVH_STACK_SIZE);
            traversal_stack[stack_ptr] = ENTRYPOINT_SENTINEL;

            node_addr = kernel_tex_fetch(__object_node, object);
          }
          else {
            /* pop */
            object = OBJECT_NONE;
            node_addr = traversal_stack[stack_ptr];
            --stack_ptr;
          }
        }
      }
    } while (node_addr != ENTRYPOINT_SENTINEL);

    if (stack_ptr >= 0) {
      kernel_assert(object != OBJECT_NONE);

      /* Instance pop. */
      if (num_hits_in_instance) {
        float t_fac;
#if BVH_FEATURE(BVH_MOTION)
        bvh_instance_motion_pop_factor(kg, object, ray, &P, &dir, &idir, &t_fac, &ob_itfm);
#else
        bvh_instance_pop_factor(kg, object, ray, &P, &dir, &idir, &t_fac);
#endif
        /* Scale isect->t to adjust for instancing. */
        for (int i = 0; i < num_hits_in_instance; i++) {
          (isect_array - i - 1)->t *= t_fac;
        }
      }
      else {
#if BVH_FEATURE(BVH_MOTION)
        bvh_instance_motion_pop(kg, object, ray, &P, &dir, &idir, FLT_MAX, &ob_itfm);
#else
        bvh_instance_pop(kg, object, ray, &P, &dir, &idir, FLT_MAX);
#endif
      }

      isect_t = tmax;
      isect_array->t = isect_t;

      object = OBJECT_NONE;
      node_addr = traversal_stack[stack_ptr];
      --stack_ptr;
    }
  } while (node_addr != ENTRYPOINT_SENTINEL);

  return num_hits;
}

ccl_device_inline uint BVH_FUNCTION_NAME(KernelGlobals kg,
                                         ccl_private const Ray *ray,
                                         Intersection *isect_array,
                                         const uint max_hits,
                                         const uint visibility)
{
  return BVH_FUNCTION_FULL_NAME(BVH)(kg, ray, isect_array, max_hits, visibility);
}

#undef BVH_FUNCTION_NAME
#undef BVH_FUNCTION_FEATURES
#undef NODE_INTERSECT
