// 镜台背景尘埃：folia 的 `<points><pointsMaterial size=0.03 sizeAttenuation/></points>`。
//
// three 的 PointsMaterial 没有贴图时画的是方点，尺寸随距离衰减：
// gl_PointSize = size * (视口高 / 2) / -mvPosition.z。这里同样是实例化的方形四边形。

uniform FrameInfo {
  mat4 view;
  mat4 projection;
  // xyz = 整片尘埃的漂移偏移，w = 世界尺寸
  vec4 offset_size;
  // viewport_w, viewport_h, -, -
  vec4 viewport;
}
frame_info;

in vec2 corner;
in vec3 mote_position;

out float v_fog_depth;

void main() {
  vec3 world = mote_position + frame_info.offset_size.xyz;
  vec4 mv_position = frame_info.view * vec4(world, 1.0);
  float depth = max(-mv_position.z, 0.0001);
  float point_size =
      frame_info.offset_size.w * (frame_info.viewport.y * 0.5) / depth;
  vec4 clip = frame_info.projection * mv_position;
  clip.xy += corner * point_size / frame_info.viewport.xy * clip.w;
  gl_Position = clip;
  v_fog_depth = -mv_position.z;
}
