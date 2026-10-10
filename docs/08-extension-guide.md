# 08 · 扩展指南

> 这一章是"接下来做什么"的清单。每个小节都给出**思路 + 可用的代码骨架**，
> 骨架全部基于本项目已有的库函数，可以直接粘进去跑。

---

## 0. 扩展的三种类型

| 类型 | 改哪里 | 难度 |
|------|-------|------|
| **加设置项** | `settings.glsl` + `shaders.properties` + `lang/` | ★ |
| **改现有效果** | 对应的 `lib/*.glsl` 或 `gbuffers_*.fsh` | ★★ |
| **加新通道** | 新建 `composite2.vsh/.fsh` 等 | ★★★ |

---

## 1. 加一个新的设置项（完整流程）

假设要加一个"水面反射强度"。

### ① 在 `settings.glsl` 里声明

```glsl
// 水面高光强度。0 = 没有反光，1 = 默认，2 = 刺眼。
#ifndef WATER_SPECULAR
#define WATER_SPECULAR 1.0
#endif
```

`#ifndef` 保护不能省 —— 游戏内改过之后 OptiFine 会写回这一行，
没有保护的话下次重载会报"重复定义"。

### ② 在 `shaders.properties` 里注册

```properties
screen.WORLD = FOG_DENSITY ENABLE_WATER_WAVES WATER_SPECULAR
option.WATER_SPECULAR = Water Specular
slider.WATER_SPECULAR = 0.0 0.5 1.0 1.5 2.0
```

### ③ 在 `lang/zh_CN.lang` 和 `en_US.lang` 里翻译

```properties
option.WATER_SPECULAR = 水面反光强度
```

### ④ 在代码里用它

```glsl
// gbuffers_water.fsh
color += specular * shadow * getDayFactor() * 0.8 * WATER_SPECULAR;
```

**验证**：进游戏，光影设置里应该出现新滑块。拖动它画面应该有变化。
如果滑块出现了但没效果，说明 `#define` 的名字和代码里用的不一致。

---

## 2. 加一个新的 gbuffers 程序

以"给附魔光效单独处理"为例。

### ① 新建文件

复制一份最简单的程序，改个名字：

```bash
cp shaders/gbuffers_textured.vsh shaders/gbuffers_armor_glint.vsh
cp shaders/gbuffers_textured.fsh shaders/gbuffers_armor_glint.fsh
```

程序名必须是 OptiFine 规定的（见 [`02-shader-pipeline-and-programs.md`](02-shader-pipeline-and-programs.md)）。

### ② 改片元着色器

```glsl
// gbuffers_armor_glint.fsh —— 附魔光效
#include "lib/fragment_output.glsl"
#include "lib/fog.glsl"

void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;
    if (albedo.a < alphaTestRef) discard;

    vec2 lmCoord = prepareLightmapCoord(vLightmapCoord);

    // 附魔光效是"自发光"的：不参与光照，直接输出紫色调的亮色
    vec3 color = albedo.rgb * vec3(0.85, 0.6, 1.4) * 2.0;

    float viewDistance = length(vViewPos);
    color = applyFog(color, viewDistance);

    writeGBuffers(color, vNormalView, lmCoord, 1.0, MAT_SOLID, albedo.a);
}
```

注意这里输出值超过 1（`* 2.0`），这正是**泛光**要抓的东西 ——
附魔光效会自动发光，不需要额外写代码。

---

## 3. 小而实用的效果（每个 5 行以内）

### ① 草方块顶面更亮

```glsl
// gbuffers_terrain.fsh，在 applyFog 之前
float topFace = step(0.9, normalView.y);         // 顶面法线朝上，y ≈ 1
color *= mix(0.92, 1.12, topFace);               // 顶面提亮 12%
```

### ② 下雨时地表变暗、变湿

```glsl
// 在 computeLighting 之前
albedo.rgb *= 1.0 - rainStrength * 0.3;           // 雨天变暗
float wetnessFactor = wetness * 0.5;              // 湿度
color += computeSpecular(normalView, vViewPos, vec3(1.0), 40.0) * wetnessFactor;
```

### ③ 发光方块（萤石、海晶灯、岩浆）

```glsl
// 需要先知道方块 ID。Iris 下用 block.properties 映射，
// 或在代码里用 MC 的方块 ID 常量（见下方说明）
#define BLOCK_GLOWSTONE 89.0
#define BLOCK_SEA_LANTERN 169.0

if (abs(vEntityId.x - BLOCK_GLOWSTONE) < 0.5) {
    color += albedo.rgb * vec3(1.0, 0.85, 0.5) * 1.5;    // 暖黄自发光
}
```

> **方块 ID 从哪来？**
> 1.9 之后方块没有数字 ID 了。OptiFine 的做法是在光影包里放一个
> `block.properties`，用方块名映射成数字：
>
> ```properties
> # shaders/block.properties
> block.1=glowstone
> block.2=sea_lantern
> ```
>
> 之后 `vEntityId.x` 就会是 `1.0`、`2.0`。
> Iris 同样支持这个文件。

### ④ 远处降低精度（性能）

```glsl
// gbuffers_terrain.fsh，把 computeLighting 换成：
vec3 color;
if (viewDistance > 48.0) {
    color = albedo.rgb * lmColor;              // 远处：只乘光照贴图
} else {
    float shadow = getShadowFactor(...);       // 近处：完整计算
    color = computeLighting(...);
}
```

### ⑤ 星空 / 自定义天空颜色

在 `gbuffers_skybasic.fsh` 里改：

```glsl
vec3 color = vColor.rgb;
// 把天空染成日出橙：用太阳高度做插值
vec3 sunsetTint = vec3(1.0, 0.55, 0.25);
color = mix(color, color * sunsetTint, 1.0 - getDayFactor());
```

---

## 4. 中级效果：SSAO（屏幕空间环境光遮蔽）

### 是什么

在墙角、物体接触处，来自天空的环境光会被挡住一部分，
所以这些地方应该更暗。MC 的光照贴图表达不了这么精细的遮蔽 ——
光照贴图是体素级的（1 格一个值），而 SSAO 是逐像素的。

### 思路

```
对屏幕上的每个像素：
  以它为圆心，在半径 R 内取 N 个随机方向
  把每个方向上的像素还原成三维位置
  看看它是不是"凸出来"挡在我的上面
  统计被遮挡的比例 -> 这就是遮蔽系数
```

### 需要的东西本项目都有

- `screenToView(uv, depth)` —— 屏幕坐标还原三维位置（`lib/space.glsl`）
- `colortex1.rg` —— 法线（`lib/common.glsl` 的 `decodeNormal`）
- `noisetex` —— 随机方向（`lib/noise.glsl`）
- `MAT_*` 材质标记 —— 避开不同材质的误判

### 代码骨架（放进 `composite.fsh` 的开头）

```glsl
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D depthtex0;

#define SSAO_SAMPLES 8
#define SSAO_RADIUS  0.6      // 单位：方块

float computeSSAO(vec2 uv) {
    // ① 当前像素的三维位置与法线
    float depth = texture2D(depthtex0, uv).r;
    if (depth >= 1.0) return 1.0;                  // 天空不处理
    vec3 viewPos = screenToView(uv, depth);
    vec3 normal  = decodeNormal(texture2D(colortex1, uv).rg);

    // ② 用噪声生成旋转角，让每个像素的采样方向都不同（避免出现规则条纹）
    float angle = texture2D(noisetex, uv * vec2(viewWidth, viewHeight) / 64.0).r * TAU;
    float cosA = cos(angle), sinA = sin(angle);

    float occlusion = 0.0;
    for (int i = 0; i < SSAO_SAMPLES; i++) {
        // ③ 在圆盘上取一个采样方向，并用噪声旋转
        float t = (float(i) + 0.5) / float(SSAO_SAMPLES);
        float r = sqrt(t);                          // sqrt 保证采样点均匀分布在圆盘上
        float a = t * TAU;
        vec2 dir = vec2(cos(a), sin(a)) * r;
        dir = vec2(dir.x * cosA - dir.y * sinA,
                   dir.x * sinA + dir.y * cosA);

        // ④ 从当前像素出发，沿视线方向偏移，投影回屏幕得到采样 UV
        vec3  sampleViewPos = viewPos + vec3(dir, 0.0) * SSAO_RADIUS;
        vec4  sampleClip = gbufferProjection * vec4(sampleViewPos, 1.0);
        vec2  sampleUv = sampleClip.xy / sampleClip.w * 0.5 + 0.5;

        // ⑤ 采样点的实际几何深度
        float sampleDepth = texture2D(depthtex0, sampleUv).r;
        vec3  actualPos = screenToView(sampleUv, sampleDepth);

        // ⑥ 判断：实际几何比"我所在的平面"更靠近摄像机 -> 说明有东西挡着
        float diff = actualPos.z - sampleViewPos.z;   // 视图空间 -z 是前方
        float rangeCheck = smoothstep(0.0, 1.0, SSAO_RADIUS / abs(diff));
        occlusion += step(0.02, diff) * rangeCheck;
    }

    return 1.0 - occlusion / float(SSAO_SAMPLES);
}
```

### 怎么接进管线

```glsl
// composite.fsh 里
float ao = computeSSAO(screenCoord);
vec3 color = texture2D(colortex0, screenCoord).rgb * mix(1.0, ao, 0.8);
gl_FragData[0] = vec4(color, 1.0);
```

⚠️ **坑**：
- 天空会得到 `depth = 1.0`，必须提前返回 1.0，否则天边会出现一圈黑边
- 采样半径用**世界单位**而不是屏幕像素，否则远处的 AO 会变大
- 噪声图必须每帧旋转（`frameCounter`），不然会看到固定的噪点图案
- 有了 AO 之后通常还要做一个**模糊**来去噪，否则画面全是颗粒

---

## 5. 中级效果：屏幕空间反射（SSR）

### 是什么

水面上应该能看到岸边树木的倒影。SSR 的做法是**从水面像素出发，
沿着反射方向在屏幕空间里步进**，看能不能撞到几何体。

### 核心代码

```glsl
// 在 gbuffers_water.fsh 里（水在 composite 之前渲染，所以不能做 SSR）
// 正确做法：把反射结果写进 colortex5，再在 composite 里混合
```

⚠️ 这也是本项目**故意没做 SSR** 的原因：水在 `composite` 之后才渲染，
SSR 需要访问已经渲染好的场景。要做 SSR 必须：

1. 把水的颜色输出改成"只写 G-Buffer"，不写最终颜色；
2. 在 `deferred` 或 `composite` 里读 `depthtex0` + `colortex1`，
   对水面像素做屏幕空间光线步进；
3. 把结果写回 colortex0。

这就是**延迟渲染（deferred shading）**的雏形。

### 光线步进的骨架

```glsl
vec3 traceReflection(vec3 startViewPos, vec3 rayDir, vec3 normal) {
    vec3 pos = startViewPos;

    for (int i = 0; i < 32; i++) {
        pos += rayDir * 0.5;                       // 步长，越小越精确越慢

        vec4 clip = gbufferProjection * vec4(pos, 1.0);
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
            return vec3(0.0);                      // 步进出了屏幕

        float sceneDepth = texture2D(depthtex0, uv).r;
        float rayDepth = clip.z / clip.w * 0.5 + 0.5;

        if (rayDepth > sceneDepth) {               // 撞上东西了
            return texture2D(colortex0, uv).rgb;
        }
    }
    return vec3(0.0);                              // 没撞到，返回黑色
}
```

### 已知缺陷（面试常问）

| 缺陷 | 原因 |
|------|------|
| 屏幕外的东西没反射 | 数据只存在于屏幕里 |
| 屏幕边缘有拉伸 | 步进到边缘时 UV 被 clamp |
| 薄的物体穿透 | 步长太大，跳过了遮挡物 |
| 反射的是"上一帧的画面" | colortex0 是当前帧的，但如果用在 deferred 里就会滞后 |

---

## 6. 中级效果：体积光（God Rays）

### 思路

阳光穿过树叶、窗户、云层的缝隙时，会在空气中形成可见的光柱。
本质是**大气散射**：光在路上被尘埃散射进了摄像机。

工程上的简化做法是**屏幕空间径向模糊**：

```
从太阳在屏幕上的位置出发，向当前像素方向"逆向"采样若干次并累加
越靠近太阳的采样越亮
```

### 代码骨架（放进 composite）

```glsl
uniform vec3 sunPosition;
uniform mat4 gbufferModelViewInverse;

vec3 computeGodRays(vec2 uv) {
    // ① 把太阳投影到屏幕空间，得到光柱的"源头"
    //    太阳在无穷远，所以取一个很远的点当作它的位置
    vec3 sunView = normalize(sunPosition) * 1000.0;
    vec4 clip = gbufferProjection * vec4(sunView, 1.0);
    vec2 sunScreen = clip.xy / clip.w * 0.5 + 0.5;

    // ② 太阳在屏幕外或背后 -> 没有光柱
    if (clip.w <= 0.0) return vec3(0.0);
    if (any(lessThan(sunScreen, vec2(0.0))) || any(greaterThan(sunScreen, vec2(1.0))))
        return vec3(0.0);

    // ③ 从当前像素朝太阳方向采样，累加亮度
    vec2 delta = (sunScreen - uv) / float(GODRAY_SAMPLES) * 0.5;
    vec2 sampleUv = uv;
    vec3 accum = vec3(0.0);

    for (int i = 0; i < GODRAY_SAMPLES; i++) {
        sampleUv += delta;
        // 只累加"亮"的部分，否则整个画面都会变亮
        vec3 s = texture2D(colortex0, sampleUv).rgb;
        accum += max(s - 0.8, 0.0);
    }
    return accum / float(GODRAY_SAMPLES) * GODRAY_STRENGTH;
}
```

⚠️ **必须处理"太阳在屏幕外"的情况**，否则会出现整屏拉丝。
上面的 `clip.w <= 0.0` 和边界检查就是干这个的。

---

## 7. 进阶：从 gbuffer 光照改成延迟光照

本项目现在是在 `gbuffers_*.fsh` 里直接算光照的。改成延迟渲染的步骤：

### ① gbuffers 只写 G-Buffer

```glsl
// gbuffers_terrain.fsh 改成
writeGBuffers(albedo.rgb, normalView, lmCoord, 0.0, MAT_SOLID, albedo.a);
//              ↑ 直接写材质颜色，不算光照
```

同时在 `lib/fragment_output.glsl` 里把 G-Buffer 扩成 4 张
（法线、反照率、光照贴图、位置/深度）。

### ② 新建 deferred 程序

```
shaders/deferred.vsh   （和 composite.vsh 一样，全屏四边形）
shaders/deferred.fsh   （读 G-Buffer，算光照，写 colortex0）
```

```glsl
// deferred.fsh
uniform sampler2D colortex1;   // 法线
uniform sampler2D colortex2;   // 光照贴图坐标
uniform sampler2D depthtex0;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    vec3 albedo = texture2D(colortex0, uv).rgb;
    vec3 normal = decodeNormal(texture2D(colortex1, uv).rg);
    vec2 lmCoord = texture2D(colortex2, uv).rg;
    vec3 lmColor = sampleLightmapColor(lmCoord);

    vec3 color = computeLighting(albedo, normal, lmColor, lmCoord, 1.0);
    gl_FragData[0] = vec4(color, 1.0);
}
```

### ③ 优势与代价

| | gbuffer 光照（现在） | 延迟光照 |
|---|---|---|
| 实现难度 | 简单 | 复杂 |
| 支持多光源 | 差（每个光源都要重算） | 好（只算一次，能加任意多光源） |
| 支持 SSAO/SSR | 难 | 容易（数据都在 G-Buffer 里） |
| 半透明物体 | 天然支持 | **需要特殊处理**（水在 G-Buffer 之后渲染，没有它的几何数据） |
| 带宽 | 低 | 高（每帧多读几张全屏纹理） |

**建议**：先用本项目把光照搞懂，再迁移。
迁移过程中最大的坑就是**半透明物体** —— 这也是为什么几乎所有
延迟渲染的光影，水都要单独处理一遍。

---

## 8. 进阶：接触硬化阴影（PCSS）

标准 PCF 的阴影边缘总是同样模糊，不真实。
真实的软阴影是这样的：

```
              光源面积大
        ┌──────────────┐
        │              │
   遮挡物 ████          │
        │    ╲          │
   ─────┴─────╲─────────┴───── 地面
        ↑ 近处锐利  ↑ 远处模糊
```

实现思路：

```glsl
// ① 先做一次大范围的采样，估算"遮挡物平均有多远"
float blockerSearch(vec2 uv, float depth) {
    float blockerSum = 0.0, count = 0.0;
    for (...) {
        float d = texture2D(shadowMap, uv + offset).r;
        if (d < depth) { blockerSum += d; count += 1.0; }   // 比我还近 -> 是遮挡物
    }
    return count > 0.0 ? blockerSum / count : -1.0;
}

// ② 遮挡物离得越远，半影越大，采样半径就越大
float penumbra = (depth - blockerDepth) / blockerDepth;
float radius = clamp(penumbra * PENUMBRA_SCALE, minRadius, maxRadius);

// ③ 用这个半径做 PCF
```

代价：每个像素至少 2 轮采样（找遮挡物 + PCF），
而且半径不固定，**采样数要取大一些**。性能开销约为普通 PCF 的 3 倍。

---

## 9. 性能向：可分离高斯模糊

`composite1.fsh` 现在是 5×5 = 25 次采样。改成两步：

```glsl
// composite1.fsh：只做【水平】方向
vec3 sum = vec3(0.0); float wsum = 0.0;
for (int i = -4; i <= 4; i++) {
    float w = exp(-float(i*i) / (2.0 * sigma * sigma));
    sum += texture2D(colortex3, screenCoord + vec2(float(i), 0.0) * texelSize * radius).rgb * w;
    wsum += w;
}
gl_FragData[0] = vec4(sum / wsum, 1.0);
```

```glsl
// composite2.fsh：读 colortex4，只做【垂直】方向，写 colortex5
```

同样的视觉效果，采样数从 **25 降到 9**，而且半径可以开得更大
（`i` 循环到 ±8 也只有 17 次采样，效果远比 5×5 的 25 次好）。

新建 `composite2.vsh/.fsh` 后，记得在 `final.fsh` 里改成读 `colortex5`。

---

## 10. 想深入可以做什么

按难度排序，每一步都只需要改一两个文件：

| 项目 | 涉及文件 | 学到什么 |
|------|---------|---------|
| 草叶随风摆动 | `gbuffers_terrain.vsh` | 顶点动画、材质判断 |
| 昼夜色调曲线 | `lib/lighting.glsl` | 颜色科学 |
| 雨天水面涟漪 | `lib/water.glsl` | 噪声、UV 扰动 |
| 屏幕空间接触阴影（SSCT） | `composite.fsh` | 屏幕空间技术 |
| 景深（DoF） | `composite.fsh` | 深度重建、模糊 |
| 时间抗锯齿（TAA） | 新增 `composite3` | 帧间数据复用、运动向量 |
| 自定义天空盒 | `gbuffers_skybasic.fsh` | 程序化纹理 |
| 支持资源包的自发光贴图 | `gbuffers_terrain.fsh` | 读取额外贴图（`texture` 之外的 sampler） |

### 从哪里找参考

- **GLSL 语法**：[GLSL-Card](https://github.com/wshxbqq/GLSL-Card)（中文速查表）
- **OptiFine 规范**：光影包根目录的 `shaders.txt`（OptiFine 自带），
  列出了所有 uniform、attribute、程序名
- **读成熟光影**：BSL、Complementary、Chocapic13 都是开源的，
  在 GitHub 上搜关键字（比如 `#define SHADOW`）能直接找到对应实现
- **中文社区**：[MineGraph 文档](https://docs.minegraph.cn/)

---

下一章：[`09-reference-sheet.md`](09-reference-sheet.md) —— 需要时随时来查。
