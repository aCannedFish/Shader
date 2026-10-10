# 05 · 阴影映射

> 对照代码读：[`lib/shadow.glsl`](../shaders/lib/shadow.glsl) 与
> [`shadow.vsh`](../shaders/shadow.vsh)。
> 阴影是光影里最容易做错的部分，这一章把每个参数的作用和它对应的画面症状讲清楚。

---

## 1. 核心思想：从光源的视角看一眼

判断"这个点有没有被挡住"，最朴素的想法是：

> 从这个点朝太阳射一条线，看看中间有没有东西。

但在 GPU 上没法真的"射一条线"（那是光线追踪）。
阴影贴图（Shadow Mapping）的做法是**反过来**：

```
① 把摄像机搬到太阳的位置，朝场景"拍一张照"，
   但只记录每个像素的【深度】，不记颜色 -> 这就是 shadowMap

② 渲染场景时，把当前像素也投影到太阳的视角下，得到：
      - 它落在 shadowMap 的哪个位置（UV）
      - 它到太阳的深度（depth）

③ 比较这两个深度：
      depth == shadowMap 里的深度    -> 它是朝太阳的第一个表面 -> 受光 ✅
      depth >  shadowMap 里的深度    -> 它前面还有东西挡住了   -> 阴影 ❌
```

**"阴影贴图 = 从光源视角再渲染一遍深度"** —— 记住这句话，
所有后续细节都是它的推论。

---

## 2. 顶点着色器做了什么

```glsl
// shadow.vsh（简化）
vec4 shadowClipPos = gl_ProjectionMatrix * gl_ModelViewMatrix * gl_Vertex;
shadowClipPos.xyz = distortShadow(shadowClipPos.xyz);
gl_Position = shadowClipPos;
```

对照 `gbuffers_terrain.vsh` 会发现公式几乎一样，只是矩阵换了：

| 玩家视角 | 太阳视角 |
|---------|---------|
| `gl_ProjectionMatrix * gl_ModelViewMatrix` | `gl_ProjectionMatrix * gl_ModelViewMatrix`（阴影通道） |

**这里没有 `gbufferModelViewInverse`**，原因见
[`03-coordinate-spaces.md`](03-coordinate-spaces.md) 第 6 节：
阴影通道的内置模型视图矩阵已包含当前区块或实体的变换。

片元着色器 `shadow.fsh` 几乎什么都不做，只做一件事：

```glsl
vec4 albedo = texture2D(texture, vTexCoord) * vColor;
if (albedo.a < alphaTestRef) discard;      // 树叶的镂空必须在这里也生效
```

⚠️ **漏掉这个 alpha 测试会怎样**：
树叶的贴图是一张正方形，其中大部分是透明的。
如果不 discard，树会投下一整块**方形的实体影子**，
树底下完全黑掉 —— 这是最经典的"新手阴影 bug"。

---

## 3. 片元着色器：深度比较

```glsl
// 1. 畸变后的裁剪坐标 -> UV + 深度
vec3 shadowUv = shadowClipPos.xyz / shadowClipPos.w * 0.5 + 0.5;

// 2. 采样阴影贴图，比较深度
float shadowDepth = texture2D(shadowtex0, shadowUv.xy).r;
float lit = step(shadowUv.z - bias, shadowDepth);
```

`step(edge, x)`：`x >= edge` 返回 1，否则 0。

```
  shadowDepth（贴图里记录的深度）
        │
        │   ← 这是朝太阳最近的表面
        │
  shadowUv.z（当前像素的深度）
        │
   如果当前像素比记录值更"远"，说明它被挡住了 -> 0
```

### 为什么要减 `bias`

因为浮点精度有限：**表面和它自己比较时可能因为误差而判成"在阴影里"**，
于是表面上会出现一条条条纹状的自阴影 —— 这叫 **shadow acne（阴影痤疮）**。

```
正确                    有 acne
┌─────────┐            ┌─────────┐
│         │            │ /////／ │   ← 表面自己挡自己
│  ☀      │            │  ☀      │
└─────────┘            └─────────┘
```

减去一个小的 `bias` 相当于"把比较的门槛抬高一点"，
让表面判为受光。

### 入射角相关的 bias

光线越斜（`N·L` 越小），同样的几何误差在深度上的投影越大，
需要的 bias 就越大：

```glsl
float NdotL = clamp(dot(normalView, lightDirView), 0.0, 1.0);
float bias = mix(SHADOW_BIAS * 8.0, SHADOW_BIAS, NdotL);
//               ↑ 掠射时用 8 倍偏移        ↑ 正对时用基础偏移
```

这个技巧叫 **slope-scaled bias（斜率缩放偏移）**，
是消除 acne 的标准手段。

| 症状 | 原因 | 怎么调 |
|------|------|-------|
| 表面有条纹状自阴影 | bias 太小 | 调大 `SHADOW_BIAS` |
| 阴影和物体"脱开"、悬空 | bias 太大 | 调小 `SHADOW_BIAS` |
| 只在小角度出现条纹 | 没有做斜率缩放 | 检查 `mix(...)` 那行 |

### `peter-panning`（彼得潘现象）

bias 太大的另一个后果：阴影从物体底部"脱落"，
看起来像物体飘在空中。**这是 bias 的固有代价**，
更好的解法是 **normal offset（法线偏移）**：

```glsl
// 在顶点着色器里，沿法线把投影位置推出去一点
vec4 worldPos = gbufferModelViewInverse * viewPos;
worldPos.xyz += normalWorld * 0.05;    // 沿法线偏移半个方块
```

它不改变深度比较的门槛，而是"把采样点挪到表面外面",
既没有 acne 也不会 peter-panning。
本项目的 `lib/shadow.glsl` 注释里标注了这个改进方向，可以自己试。

---

## 4. PCF：软阴影

单个采样点得到的是"非黑即白"的硬阴影，边缘锯齿非常明显。解决办法：

**在周围多采几个点，求平均。**

```glsl
float sampleShadowPCF(vec2 uv, float depth, float bias) {
    float texelSize = 1.0 / float(shadowMapResolution);
    float shadow = 0.0, count = 0.0;

    for (int x = -SHADOW_SOFTNESS; x <= SHADOW_SOFTNESS; x++) {
        for (int y = -SHADOW_SOFTNESS; y <= SHADOW_SOFTNESS; y++) {
            vec2 offset = vec2(float(x), float(y)) * texelSize;
            shadow += sampleShadowMap(uv + offset, depth, bias);
            count += 1.0;
        }
    }
    return shadow / count;
}
```

这就是 **PCF（Percentage Closer Filtering，百分比渐进过滤）**：
把邻域的 9 个"是/否"求平均，得到 0 到 1 之间的连续值。

| `SHADOW_SOFTNESS` | 采样数 | 效果 |
|---|---|---|
| 0 | 1 | 硬阴影，锯齿明显 |
| 1 | 9 | 轻微柔和（默认） |
| 2 | 25 | 明显柔和，性能下降 |

⚠️ **PCF 不能无限加采样**。真实的软阴影需要**接触硬化**
（离物体越近阴影越锐利，越远越模糊），
标准 PCF 做不到这一点 —— 它只会让所有阴影边缘一样糊。
想要真实的软阴影，需要用 **PCSS**（根据遮挡物距离动态决定采样半径），
见 [`08-extension-guide.md`](08-extension-guide.md)。

---

## 5. 畸变：把纹素花在刀刃上

### 问题

阴影贴图覆盖的是一个边长为 `2 × shadowDistance` 的正方形。
2048² 的贴图铺在 192×192 方块上，平均**每个方块只有 10 个像素**。
而玩家真正在意的是**近处**的阴影（脚下的树影、栅栏），
远处糊一点无所谓。

### 解法

把裁剪空间坐标按"到中心的距离"向外拉伸：

```glsl
vec3 distortShadow(vec3 clipPos) {
    float dist = length(clipPos.xy);
    float factor = (1.0 - SHADOW_MAP_BIAS) + dist * SHADOW_MAP_BIAS;
    clipPos.xy /= factor;
    return clipPos;
}
```

```
不畸变                畸变后（SHADOW_MAP_BIAS = 0.9）
┌───────────────┐     ┌───────────────┐
│··· ··· ··· ···│     │   ·   ·   ·   │
│··· ··· ··· ···│     │  近处纹素密集 │
│··· ··· ··· ···│     │ ·  ·  ·  ·  · │
│ 纹素均匀分布  │     │ 远处纹素稀疏  │
└───────────────┘     └───────────────┘
```

代入公式感受一下（`dist` 是到中心的距离，范围约 `[0, 1.41]`）：

| `SHADOW_MAP_BIAS` | 中心的 factor | 边缘的 factor | 结果 |
|---|---|---|---|
| `0.0` | `1.0` | `1.0` | 不畸变，纹素均匀分布 |
| `0.9` | `0.1` | `1.0` | 中心坐标被推远，**近处纹素密度提升约 10 倍** |
| `1.0` | `0.0` | `1.0` | 除以 0，结果退化，**不要用** |

规律：**`SHADOW_MAP_BIAS` 越大，畸变越强、近处越清晰**。
常用 `0.9`，取值必须严格小于 `1.0`。

⚠️ **顶点和片元必须用同一个函数**。
本项目把它放在 `lib/space.glsl` 供两边共用，就是为了杜绝不一致。

---

## 6. 距离淡出：藏起贴图的边界

阴影贴图只覆盖 `shadowDistance` 范围。范围外没有数据，
硬判会得到"阴影突然消失"或"一圈黑边"。

本项目的做法：

```glsl
// 超出范围的直接判为受光
if (any(lessThan(shadowUv.xy, vec2(0.0))) ||
    any(greaterThan(shadowUv.xy, vec2(1.0)))) return 1.0;

// 在 75% ~ 95% 距离之间平滑淡出
float fade = 1.0 - smoothstep(shadowDistance * 0.75,
                              shadowDistance * 0.95, viewDistance);
return mix(1.0, shadow, fade);
```

用 `smoothstep` 而不是线性插值，是因为它的两端导数为 0，
过渡没有可见的"硬边"。

**调参建议**：
- `shadowDistance` 调小 -> 阴影更清晰，但远处阴影消失得更近
- 如果远处阴影消失得太突兀，把淡出区间（0.75 / 0.95）拉长

---

## 7. 性能

阴影是本项目**最贵的部分**。开销来自两处：

1. **阴影贴图的渲染**：整个场景要多画一遍
2. **采样成本**：每个像素 9 次纹理采样（`SHADOW_SOFTNESS = 1`）

优化手段（本项目已经用了前两条）：

| 手段 | 效果 |
|------|------|
| 降低分辨率（2048 -> 1024） | 显存和带宽减半，最有效 |
| 关闭阴影（`ENABLE_SHADOWS 0`） | 宏裁剪，整个通道都不执行 |
| 减小 `shadowDistance` | 正交范围变小，纹素更密 |
| 只在近处采样 | 远处直接返回 1.0（本项目用距离淡出实现了类似效果） |
| 硬件 PCF | 把 `shadowHardwareFiltering` 设为 `true`，用硬件做比较采样 |

---

## 8. 症状对照表

调试阴影时最有用的一张表：

| 画面症状 | 最可能的原因 |
|---------|------------|
| 完全没有阴影 | `ENABLE_SHADOWS` 为 0；或 `getShadowFactor` 总是返回 1 |
| 表面全是条纹（acne） | `SHADOW_BIAS` 太小 |
| 阴影悬空 / 脱离物体 | `SHADOW_BIAS` 太大 |
| 阴影整体偏移到错误位置 | 顶点阶段漏了 `gbufferModelViewInverse` |
| 阴影相对物体错位一点点 | 顶点和片元的畸变函数不一致 |
| 所有地方都在阴影里 | 深度没做透视除法（忘了 `/ w`） |
| 树叶投出方形影子 | `shadow.fsh` 漏了 alpha 测试 |
| 远处阴影突然消失 | 距离淡出区间设得太窄 |
| 阴影边缘锯齿严重 | 提高 `shadowMapResolution` 或 `SHADOW_SOFTNESS` |
| 阴影随镜头转动而抖动 | 阴影贴图没有对齐到纹素网格（进阶问题） |

**排查口诀**：先用 `DEBUG_VIEW 3` 看阴影系数图。
看到的是纯黑白 -> 说明阴影数据本身是对的，问题在光照合成；
看到的是噪点/条纹 -> 问题出在采样或 bias；
看到的是一整片黑或一整片白 -> 问题出在坐标变换。

---

下一章：[`06-post-processing-and-tonemapping.md`](06-post-processing-and-tonemapping.md)
—— 从 HDR 到屏幕。
