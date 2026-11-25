// 镜台点云片元：folia `DIORAMA_PARTICLE_FRAGMENT_SHADER` 的移植。
//
// folia 的 three.js ShaderMaterial 拿到的是线性空间颜色、自己在出口转回 sRGB；这里统一块里传的
// 就是 sRGB 主题色，出口不再转换，结果是同一个颜色。输出是预乘 alpha（Flutter 合成约定）：对比层
// 用 (one, one-minus-src-alpha) 普通混合，辉光层输出 alpha = 0 配 (one, one) 纯叠加光。

uniform FragInfo {
  // glow, glow_pass, -, -
  vec4 glow;
}
frag_info;

in vec3 v_color;
in float v_alpha;
in float v_reaction;
in vec2 v_point;

out vec4 frag_color;

void main() {
  vec2 point = v_point - vec2(0.5);
  float radius = length(point);
  float glow = frag_info.glow.x;

  if (frag_info.glow.y > 0.5) {
    float halo = pow(clamp(1.0 - radius * 2.0, 0.0, 1.0), 1.7);
    float alpha = min(0.5, halo * v_alpha * glow * 0.4);
    if (alpha < 0.003) {
      discard;
    }
    frag_color = vec4(v_color * (1.0 + glow * 0.25) * alpha, 0.0);
    return;
  }

  float core = 1.0 - smoothstep(0.14, 0.48, radius);
  float alpha = core * v_alpha;
  if (alpha < 0.01) {
    discard;
  }
  float emission = 0.95 + v_reaction * 0.22;
  frag_color = vec4(clamp(v_color * emission, 0.0, 1.0) * alpha, alpha);
}
