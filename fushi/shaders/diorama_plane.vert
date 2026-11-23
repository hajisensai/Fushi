// 镜台文字平面：一行（邻行整行图）或一个单元（当前行逐字 / 逐词图集里的一格）就是世界里的一块
// 带贴图的四边形——folia 里的 `<mesh><planeGeometry/><meshBasicMaterial map=…/></mesh>`。
//
// 实例化：槽 0 是单位方形的六个角，槽 1 每块平面给中心、两条半轴（已含朝向与世界尺寸）、
// 图集里的 uv 矩形和染色。three 的线性雾按视空间深度算（fog_vertex: vFogDepth = -mvPosition.z）。

uniform FrameInfo {
  mat4 view;
  mat4 projection;
}
frame_info;

in vec2 corner;
in vec3 center;
in vec3 axis_u;
in vec3 axis_v;
// (u0, v0, u1, v1)：左上到右下，归一化
in vec4 uv_rect;
in vec4 tint;

out vec2 v_uv;
out vec4 v_tint;
out float v_fog_depth;

void main() {
  vec3 world = center + axis_u * corner.x + axis_v * corner.y;
  vec4 mv_position = frame_info.view * vec4(world, 1.0);
  gl_Position = frame_info.projection * mv_position;
  vec2 t = corner * 0.5 + 0.5;
  // 平面 +v 朝上，图集 v 向下增长。
  v_uv = vec2(mix(uv_rect.x, uv_rect.z, t.x), mix(uv_rect.w, uv_rect.y, t.y));
  v_tint = tint;
  v_fog_depth = -mv_position.z;
}
