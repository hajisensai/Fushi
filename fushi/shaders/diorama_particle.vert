// 镜台（diorama）点云：folia `dioramaParticleShaders.ts` 顶点着色器的 Flutter GPU 移植。
//
// three.js 的 gl_PointSize 点精灵在这里是实例化的四边形：槽 0 是一个单位方形的六个角，槽 1 每个实例
// 一个点（图元本地位置 / 位移方向 / 锚点 / 缩放 / 相位与样式 / 波坐标）。位移、波纹、溶散、尺寸与
// 调色板逻辑逐行对应 folia，点的像素尺寸算出来后在裁剪空间里把角撑开，片元按 gl_PointCoord 同样的
// 0..1 坐标画圆盘 / 光晕。
//
// 所有标量都打进 vec4，统一块只含 vec4 / mat4 / vec4 数组：std140、Metal、GLES 反射三边布局一致。

#define RIPPLE_COUNT 9

uniform FrameInfo {
  mat4 view;
  mat4 projection;
  // xyz = 相机位置
  vec4 camera_position;
  // time, corridor, amplitude, max_swell
  vec4 p0;
  // wave_number_max, detail, offset_gain, flow
  vec4 p1;
  // formation, scatter, pulse, spectral_centroid
  vec4 p2;
  // viewport_w, viewport_h, size_base, size_gain
  vec4 p3;
  // glow, glow_pass, -, -
  vec4 p4;
  // 几何生命周期：fade_in_start, fade_in_end, dissolve_start, dissolve_end
  vec4 life;
  vec4 primary_color;
  vec4 accent_color;
  vec4 secondary_color;
  // 波纹源：云 = 单位球上的起点（xyz），长廊 = 管壁上的 (along, angle)；w = 出生时间
  vec4 ripple_source[RIPPLE_COUNT];
  // x = 强度, y = 速度, z = 波包宽, w = 波数
  vec4 ripple_shape[RIPPLE_COUNT];
}
frame_info;

in vec2 corner;
in vec3 base_position;
in vec3 normal_dir;
in vec3 anchor;
// (整体缩放, 竖向拉伸, 图元半径)
in vec3 scale;
// (相位, 颜色槽, 远景, -)
in vec4 style;
// 长廊：(沿管道的半径单位, 绕管角)；云：溶散种子
in vec2 wave;

out vec3 v_color;
out float v_alpha;
out float v_reaction;
out vec2 v_point;

float hermite(float value) {
  return value * value * (3.0 - 2.0 * value);
}

float hash11(float n) {
  return fract(sin(n) * 43758.5453123);
}

float resolveLife(float distance_to_camera) {
  vec4 l = frame_info.life;
  float far_t = clamp((l.y - distance_to_camera) / (l.y - l.x), 0.0, 1.0);
  float near_t = clamp((distance_to_camera - l.w) / (l.z - l.w), 0.0, 1.0);
  return hermite(far_t) * hermite(near_t);
}

float ripplePacket(float r, float age, vec4 shape) {
  float dr = r - age * shape.y;
  float k = min(shape.w, frame_info.p1.x);
  float packet = exp(-(dr * dr) / (shape.z * shape.z)) * sin(dr * k);
  return shape.x * packet * exp(-age * 1.15) * exp(-r * 0.35);
}

float cloudRipples(vec3 unit_pos, float phase) {
  float spin = cos(phase);
  float spun = sin(phase);
  float total = 0.0;
  for (int i = 0; i < RIPPLE_COUNT; i += 1) {
    vec4 source = frame_info.ripple_source[i];
    vec4 shape = frame_info.ripple_shape[i];
    float age = frame_info.p0.x - source.w;
    if (shape.x <= 0.0 || age < 0.0) {
      continue;
    }
    vec3 origin = vec3(source.x * spin - source.z * spun, source.y,
                       source.x * spun + source.z * spin);
    total += ripplePacket(distance(unit_pos, origin), age, shape);
  }
  return total;
}

vec2 corridorSurfaceDelta(vec2 w, vec2 origin) {
  float d_angle = w.y - origin.y;
  return vec2(w.x - origin.x, atan(sin(d_angle), cos(d_angle)));
}

float corridorRipples(vec2 w) {
  float total = 0.0;
  for (int i = 0; i < RIPPLE_COUNT; i += 1) {
    vec4 source = frame_info.ripple_source[i];
    vec4 shape = frame_info.ripple_shape[i];
    float age = frame_info.p0.x - source.w;
    if (shape.x <= 0.0 || age < 0.0) {
      continue;
    }
    total += ripplePacket(length(corridorSurfaceDelta(w, source.xy)), age,
                          shape);
  }
  return total;
}

float cloudIdle(vec3 unit_pos) {
  float t = frame_info.p0.x;
  return 0.11 * sin(unit_pos.x * 1.7 + t * 0.5) *
             cos(unit_pos.z * 1.4 - t * 0.37) +
         0.06 * sin(unit_pos.y * 2.1 - t * 0.66);
}

float corridorIdle(vec2 w) {
  float t = frame_info.p0.x * frame_info.p1.w;
  float region = 0.6 + 0.4 * sin(w.x * 0.42 - t * 0.33);
  float ripple = 0.62 * sin(w.x * 1.25 - t * 1.15) +
                 0.30 * sin(w.x * 0.8 + w.y * 2.0 - t * 0.8) +
                 0.08 * sin(w.y * 3.0 + t * 0.5);
  return region * ripple;
}

float cloudDetail(vec3 p) {
  float k = frame_info.p1.x * 0.7;
  float t = frame_info.p0.x;
  return sin(p.x * k + t * 3.1) * sin(p.y * k - t * 2.6) *
         sin(p.z * k + t * 2.2);
}

float corridorDetail(vec2 w) {
  float k = frame_info.p1.x * 0.7;
  float n = max(1.0, floor(k));
  float t = frame_info.p0.x;
  return sin(w.x * k + t * 3.1) * sin(w.y * n - t * 2.4);
}

void main() {
  float time = frame_info.p0.x;
  float amplitude = frame_info.p0.z;
  float phase = style.x;
  float color_slot = style.y;
  float is_far = style.z;
  vec3 n_dir = normalize(normal_dir);
  float local_radius = scale.z;

  vec3 base_pos = base_position;
  base_pos.y *= scale.y;

  vec3 unit_pos = base_position / local_radius;
  bool corridor = frame_info.p0.y > 0.5;
  float audio = corridor ? corridorRipples(wave) : cloudRipples(unit_pos, phase);
  float idle = corridor ? corridorIdle(wave) : cloudIdle(unit_pos);

  float detail = frame_info.p1.y * smoothstep(0.06, 0.45, abs(audio));
  audio += (corridor ? corridorDetail(wave) : cloudDetail(unit_pos)) * detail *
           0.3;

  float swell = clamp(audio + idle, -1.6, 1.6) * amplitude;
  vec3 displaced = base_pos + n_dir * (swell * local_radius);
  float d = clamp(abs(clamp(audio, -1.6, 1.6) * amplitude) /
                      max(frame_info.p0.w, 0.0001),
                  0.0, 1.0);

  displaced.z +=
      sin(time * 0.6 + phase) * 0.12 * frame_info.p1.z * local_radius;

  float scatter = 1.0 - frame_info.p2.x;
  if (scatter > 0.001) {
    float r1 = hash11(phase * 12.9898 + wave.x * 78.233);
    float r2 = hash11(phase * 39.346 + wave.y * 11.135 + 3.7);
    float r3 = hash11(r1 * 91.7 + r2 * 47.3);
    vec3 spread =
        normalize(n_dir * 0.75 + vec3(r1 - 0.5, r2 - 0.5, r3 - 0.5) * 1.6);
    displaced +=
        spread * (scatter * scatter * frame_info.p2.y * (0.55 + r3 * 0.9));
  }

  displaced *= scale.x * frame_info.p2.z;
  vec3 world_position = anchor + displaced;

  float life =
      resolveLife(distance(world_position, frame_info.camera_position.xyz));
  vec4 mv_position = frame_info.view * vec4(world_position, 1.0);

  float glow = frame_info.p4.x;
  float glow_pass = frame_info.p4.y;
  float glow_scale = mix(1.0, 1.9 + glow * 1.3, glow_pass);
  float size_world =
      (frame_info.p3.z + (pow(d, 3.0) + detail * 0.35) * frame_info.p3.w) *
      glow_scale;
  float projected = size_world * frame_info.p3.y *
                    frame_info.projection[1][1] * 0.5 /
                    max(-mv_position.z, 0.1);
  float point_size = clamp(projected, mix(1.4, 2.0, glow_pass),
                           mix(26.0, 64.0, glow_pass));
  vec4 clip = frame_info.projection * mv_position;
  // 点精灵：像素尺寸换成裁剪空间偏移（NDC 半宽 = 像素 / 视口）。
  clip.xy += corner * point_size / frame_info.p3.xy * clip.w;
  gl_Position = clip;
  v_point = corner * 0.5 + 0.5;

  float gradient_phase =
      (dot(base_pos, vec3(0.2, 0.16, 0.13)) + phase * 0.05 +
       color_slot * 0.5 + time * 0.02 + frame_info.p2.w * 0.3) *
      6.283;
  vec3 wgt = max(vec3(0.0),
                 0.5 + 0.5 * cos(gradient_phase - vec3(0.0, 2.094, 4.188)));
  wgt *= wgt;
  wgt /= max(wgt.x + wgt.y + wgt.z, 0.001);
  vec3 base_color = frame_info.primary_color.rgb * wgt.x +
                    frame_info.accent_color.rgb * wgt.y +
                    frame_info.secondary_color.rgb * wgt.z;
  vec3 hot_color =
      mix(frame_info.accent_color.rgb, frame_info.secondary_color.rgb,
          smoothstep(0.2, 0.9, frame_info.p2.w));
  float hot = min(1.0, smoothstep(0.1, 0.75, d) * 0.75 + detail * 0.3);
  v_color = mix(base_color, hot_color, hot) * (0.92 + d * 0.5);

  float layer_base = mix(0.72, 0.5, is_far);
  float formed = smoothstep(0.0, 0.45, frame_info.p2.x);
  v_alpha = formed * (glow_pass > 0.5
                          ? life * smoothstep(0.1, 0.8, d) * 1.15
                          : life * min(1.0, layer_base + d * 0.28));
  v_reaction = d;
}
