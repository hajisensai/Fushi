// 镜台文字平面片元：three `meshBasicMaterial`（color × map，opacity，雾）。
//
// 字图是白字（预乘 alpha，rgb = a），染色取 tint.rgb，透明度 = 贴图 a × tint.a。雾按 three 的线性雾
// 把颜色往背景色推（smoothstep(near, far, depth)），alpha 不变。普通混合输出预乘色；叠加层
// （辉光 / 灵魂出窍）输出 alpha = 0、配 (one, one) 混合，只加光不遮挡。

uniform sampler2D atlas;

uniform FragInfo {
  // rgb = 雾色（阻尼后的背景色）
  vec4 fog_color;
  // fog_near, fog_far, additive, -
  vec4 params;
}
frag_info;

in vec2 v_uv;
in vec4 v_tint;
in float v_fog_depth;

out vec4 frag_color;

void main() {
  float coverage = texture(atlas, v_uv).a;
  float alpha = coverage * v_tint.a;
  if (alpha < 0.002) {
    discard;
  }
  float fog = smoothstep(frag_info.params.x, frag_info.params.y, v_fog_depth);
  vec3 color = mix(v_tint.rgb, frag_info.fog_color.rgb, fog);
  if (frag_info.params.z > 0.5) {
    frag_color = vec4(color * alpha, 0.0);
  } else {
    frag_color = vec4(color * alpha, alpha);
  }
}
