/*
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

#include "UI_interface.h"
#include "UI_resources.h"

#include "node_geometry_util.hh"

extern "C" {
Mesh *triangulate_mesh(Mesh *mesh,
                       const int quad_method,
                       const int ngon_method,
                       const int min_vertices,
                       const int flag);
}

namespace blender::nodes::node_geo_triangulate_cc {

static void node_declare(NodeDeclarationBuilder &b)
{
  b.add_input<decl::Geometry>(N_("Mesh")).supported_type(GEO_COMPONENT_TYPE_MESH);
  b.add_input<decl::Int>(N_("Minimum Vertices")).default_value(4).min(4).max(10000);
  b.add_output<decl::Geometry>(N_("Mesh"));
}

static void node_layout(uiLayout *layout, bContext *UNUSED(C), PointerRNA *ptr)
{
  uiItemR(layout, ptr, "quad_method", 0, "", ICON_NONE);
  uiItemR(layout, ptr, "ngon_method", 0, "", ICON_NONE);
}

static void geo_triangulate_init(bNodeTree *UNUSED(ntree), bNode *node)
{
  node->custom1 = GEO_NODE_TRIANGULATE_QUAD_SHORTEDGE;
  node->custom2 = GEO_NODE_TRIANGULATE_NGON_BEAUTY;
}

static void node_geo_exec(GeoNodeExecParams params)
{
  GeometrySet geometry_set = params.extract_input<GeometrySet>("Mesh");
  const int min_vertices = std::max(params.extract_input<int>("Minimum Vertices"), 4);

  GeometryNodeTriangulateQuads quad_method = static_cast<GeometryNodeTriangulateQuads>(
      params.node().custom1);
  GeometryNodeTriangulateNGons ngon_method = static_cast<GeometryNodeTriangulateNGons>(
      params.node().custom2);

  geometry_set.modify_geometry_sets([&](GeometrySet &geometry_set) {
    /* #triangulate_mesh might modify the input mesh currently. */
    Mesh *mesh_in = geometry_set.get_mesh_for_write();
    if (mesh_in != nullptr) {
      Mesh *mesh_out = triangulate_mesh(mesh_in, quad_method, ngon_method, min_vertices, 0);
      geometry_set.replace_mesh(mesh_out);
    }
  });

  params.set_output("Mesh", std::move(geometry_set));
}
}  // namespace blender::nodes::node_geo_triangulate_cc

void register_node_type_geo_triangulate()
{
  namespace file_ns = blender::nodes::node_geo_triangulate_cc;

  static bNodeType ntype;

  geo_node_type_base(&ntype, GEO_NODE_TRIANGULATE, "Triangulate", NODE_CLASS_GEOMETRY);
  ntype.declare = file_ns::node_declare;
  node_type_init(&ntype, file_ns::geo_triangulate_init);
  ntype.geometry_node_execute = file_ns::node_geo_exec;
  ntype.draw_buttons = file_ns::node_layout;
  nodeRegisterType(&ntype);
}
