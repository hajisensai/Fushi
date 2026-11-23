// 镜台背景尘埃片元：PointsMaterial 的纯色 × 透明度，加 three 线性雾。

uniform FragInfo {
  // rgb = 颜色，a = 透明度
  vec4 color;
  vec4 fog_color;
  // fog_near, fog_far, -, -
  vec4 params;
}
frag_info;

in float v_fog_depth;

out vec4 frag_color;

void main() {
  float fog = smoothstep(frag_info.params.x, frag_info.params.y, v_fog_depth);
  vec3 color = mix(frag_info.color.rgb, frag_info.fog_color.rgb, fog);
  float alpha = frag_info.color.a;
  frag_color = vec4(color * alpha, alpha);
}
