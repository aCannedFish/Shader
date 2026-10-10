# 06 · 后处理与色调映射

> 对照代码读：[`lib/tonemap.glsl`](../shaders/lib/tonemap.glsl)、
> [`composite.fsh`](../shaders/composite.fsh)、
> [`final.fsh`](../shaders/final.fsh)。
> 这一章解释三个新手最常问的问题：为什么画面发灰？为什么高光死白？
> 为什么加完泛光就糊了？

---

## 1. 线性空间 vs 显示空间

### 一切问题的根源

物理上，光的强度是可加的：

```
两个 50 瓦的灯泡 = 一个 100 瓦的灯泡
```

但**显示器不是这么工作的**。显示器接收到的数值和它发出来的光强
是**幂函数关系**：

```
发出的光 ≈ 输入值 ^ 2.2
```

这叫 **gamma 编码**。它是历史遗留（早期 CRT 显示器的物理特性），
但现在所有显示器都沿用了这个约定。

### 这意味着什么

如果你直接把物理上正确的光强 `0.5` 发给显示器：

```
显示器发出 = 0.5 ^ 2.2 = 0.22
```

**画面会比应该的暗一半以上。** 这就是"画面发灰发暗"的根本原因。

### 正确的做法

```
计算阶段：用【线性空间】—— 光是可加的，物理正确
    ↓
显示阶段：转成【显示空间】—— 做 1/2.2 次方
```

```glsl
// final.fsh 里的最后一步
color = pow(max(color, 0.0), vec3(1.0 / 2.2));
```

本项目里：
- **所有 gbuffers 程序输出线性颜色**
- **所有的混合（雾、泛光、透明度）都在线性空间完成**
- **只有 `final.fsh` 做一次 gamma 编码**

⚠️ **新手最常见的错误**：在 gbuffers 里就 `pow(color, 1/2.2)`，
然后 `final` 又做一次 —— 画面会**亮得发光**，颜色完全失真。

### sRGB 贴图的问题

Minecraft 的方块贴图是 **sRGB 编码**的（它们本身就是给显示器看的）。
严格来说应该在采样后先转成线性：

```glsl
vec3 albedoLinear = pow(albedo.rgb, vec3(2.2));
```

本项目在 `lib/color_space.glsl` 中统一转换贴图、顶点色、光照贴图、
天空色和雾色。这样黄昏时天空与远处地形使用同一颜色空间，
最后由 `final.fsh` 统一映射和编码。

---

## 2. 为什么要 HDR

### 问题

现实世界的亮度跨度极大：

| 场景 | 亮度（nit） |
|------|-----------|
| 正午雪面 | ~10000 |
| 阴天 | ~1000 |
| 室内灯光 | ~100 |
| 月光地面 | ~0.1 |

显示器只能显示 `0 ~ 1`（约 100 nit）。如果把大于 1 的部分直接**截断**：

```
计算值：  0.8   1.2   3.5   12.0
截断后：  0.8   1.0   1.0   1.0     ← 后三个全都变成一样的纯白
```

**结果**：太阳、爆炸、附魔光效全部糊成一片死白，细节全丢。

### 解法：色调映射

用一条曲线把 `[0, ∞)` 压缩到 `[0, 1)`：

```
输出
 1.0 ┤                    ╭────────────  截断（不好）：全平了
     │              ╭─────╯
     │         ╭────╯
 0.5 ┤     ╭───╯  ← 色调映射（好）：永远在涨，只是越来越慢
     │  ╭──╯
   0 ┤──╯
     └──┬────┬────┬────┬────┬──→ 输入
        1    2    4    8   16
```

曲线**永远在上升**意味着：再亮的东西之间也还有差别，
只是差别被压缩了 —— 这才是"高光还有细节"。

### 前置条件：缓冲区必须是浮点

如果 `colortex0` 是普通的 `RGBA8`，那么 `3.5` 在写进去的时候就变成 `1.0` 了，
色调映射拿到的全是 1.0，**什么也救不回来**。

所以 `settings.glsl` 里要声明成浮点格式：

```glsl
/*
const int colortex0Format = RGBA16F;   // 16 位浮点，能存下大于 1 的值
*/
```

⚠️ **注意这行必须包在块注释里。** `RGBA16F` 是 OptiFine 的语法而不是合法 GLSL，
不注释掉的话 GLSL 编译器会报 `undeclared identifier`，
导致整个程序链接失败（现象是画面只剩天空）。
细节见 [`07-debugging-and-performance.md`](07-debugging-and-performance.md) 的"只看到天空"一节。

---

## 3. 三种色调映射曲线

### 方案 0：不映射（直接截断）

```glsl
color = clamp(color, 0.0, 1.0);
```

留着是为了对照 —— 切到这个模式能直观看到"死白"长什么样。

### 方案 1：Reinhard

```glsl
vec3 tonemapReinhard(vec3 color) {
    return color / (1.0 + color);
}
```

- `color = 1` -> `0.5`
- `color = 10` -> `0.91`
- `color = ∞` -> `1.0`（永远不超标）

**优点**：简单，绝不会过曝。
**缺点**：整体偏灰、对比度低，暗部被压得太狠。

### 方案 2：ACES（默认）

```glsl
vec3 tonemapACES(vec3 color) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    vec3 numerator   = color * (a * color + b);
    vec3 denominator = color * (c * color + d) + e;
    return clamp(numerator / denominator, 0.0, 1.0);
}
```

这是电影工业标准 ACES 曲线的一个多项式拟合，特点是：

- **肩部**（高光）压缩得比 Reinhard 更自然，亮部不会一起变成灰白
- **趾部**（暗部）有一点提亮，暗处细节更清楚
- 颜色会略微向暖色偏移，这就是"电影感"的来源

**实践建议**：日常用 ACES。想调出特定风格时，
在 `applyTonemap()` 里换成自己的曲线，或者串联多条曲线。

---

## 4. 曝光、饱和度、对比度

这三个是"调色"参数，顺序很重要：

```glsl
vec3 applyTonemap(vec3 color) {
    color *= EXPOSURE;                       // ① 映射【前】调整
    color = tonemapACES(color);              // ② 曲线
    color = applySaturation(color, SATURATION);  // ③ 映射【后】调色
    color = applyContrast(color, CONTRAST);
    return color;
}
```

**为什么曝光在映射前**：曝光是"相机的进光量"，是一个**线性缩放**。
在物理上它应该发生在"光进入传感器"的时候，也就是映射之前。
映射之后再乘系数，效果就不是等价的（高光会被推到不同的压缩区间）。

**为什么饱和度/对比度在映射后**：它们是对"已经成型的图像"做艺术加工。
映射后的值域固定在 `[0,1]`，此时调色结果稳定、可预测。

### 饱和度

```glsl
vec3 applySaturation(vec3 color, float amount) {
    float gray = luma(color);              // 感知亮度
    return mix(vec3(gray), color, amount); // 在灰色和原色之间插值
}
```

| `amount` | 效果 |
|---|---|
| 0 | 完全灰度 |
| 1 | 不变 |
| 1.2 | 略微鲜艳 |
| 2 | 严重过饱和（颜色会溢出） |

⚠️ **`luma` 不能用 `(r+g+b)/3`**。人眼对绿色最敏感、蓝色最不敏感，
必须用加权和：

```glsl
float luma(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));   // Rec.709
}
```

用简单平均会让红色和蓝色的亮度观感明显偏亮。

### 对比度

```glsl
vec3 applyContrast(vec3 color, float amount) {
    return (color - 0.5) * amount + 0.5;
}
```

以中灰 `0.5` 为轴心拉伸。`amount > 1` 时亮部更亮、暗部更暗。

---

## 5. 泛光（Bloom）

### 是什么

真实的眼睛和相机镜头都不是完美的：强光会**溢出到周围**。
这就是"逆光时整个画面发白"、
"夜里看路灯周围有一圈光晕"的原因。

### 三步走

```
① composite.fsh   亮部提取：只保留亮度超过阈值的像素
       ↓  colortex3
② composite1.fsh  高斯模糊：把这团亮部糊开
       ↓  colortex4
③ final.fsh       叠加：color += bloom × 强度
```

### ① 亮部提取：为什么用"软阈值"

```glsl
float brightness = luma(color);
float contribution = max(brightness - BLOOM_THRESHOLD, 0.0) / max(brightness, EPSILON);
gl_FragData[0] = vec4(color * contribution, 1.0);
```

硬阈值写法是 `brightness > threshold ? color : 0`，问题在于：
亮度刚好在阈值附近的像素会**突然开始发光**，
画面移动时能看到明显的闪烁边界。

`contribution` 这个式子的含义是"超过阈值的部分占原亮度的比例"：

```
brightness = 0.5,  threshold = 0.85  ->  contribution = 0     不发光
brightness = 1.0,  threshold = 0.85  ->  contribution = 0.15  发一点
brightness = 5.0,  threshold = 0.85  ->  contribution = 0.83  发很多
```

过渡是连续的，没有突变。

### ② 高斯模糊

```glsl
float weight = exp(-distSq / twoSigmaSq);   // 高斯权重
sum += texture2D(colortex3, uv + offset).rgb * weight;
weightSum += weight;
...
return sum / weightSum;                     // 归一化
```

**为什么是高斯而不是方框平均**：方框平均（直接取周围平均值）
会在模糊边缘留下方块状的痕迹；高斯权重是钟形的，过渡自然。

**为什么要除以 `weightSum`**：不然模糊后整体亮度会变化
（每个像素累加了 25 个邻居的值，不归一化就亮了 25 倍）。

⚠️ **模糊半径不能太大**。半径 8 像素以内还算正常，
再大就会出现"采样点之间的空隙"（能看到一个个孤立的光斑）。
工业界的解法是**多级降采样**：把图缩小到 1/2、1/4、1/8 各模糊一次再叠加，
用很小的采样核实现很大的模糊范围。

### ③ 叠加

```glsl
color += bloom * BLOOM_STRENGTH;    // 在色调映射【之前】加
```

**为什么必须加在色调映射前**：泛光是"光"，它应该和场景一起被映射。
如果先映射再加，泛光部分不会被压缩，会直接过曝成一片白。

---

## 6. 抖动（Dithering）

### 问题：8 位色深只有 256 级

天空、雾这类大面积平滑渐变，相邻两级颜色之间的边界会被眼睛
连成一条条同心圆状的**色带（banding）**：

```
理想          实际（8 位）
▓▓▓▓▓▓        ▓▓▓▓▓▓▓▓
▒▒▒▒▒▒        ▓▓▓▓▓▓▓▓  ← 一整条边
░░░░░░        ▒▒▒▒▒▒▒▒
              ░░░░░░░░  ← 又一整条边
```

### 解法：加一点点噪声

```glsl
float noise = texture2D(noisetex, noiseCoord).r;
float offset = (noise - 0.5) / 255.0 * DITHER_STRENGTH;
return color + offset;
```

偏移量**小于一个色阶**（`1/255`），所以它不会真的改变颜色，
只会让"该舍入到上面还是下面"这件事变得随机 ——
色带边界被打散成噪点，而人眼会自动忽略随机噪点。

⚠️ **抖动必须放在 gamma 编码之后**。因为色带是在**最终显示值**上产生的，
在这之前做毫无意义。

### 为什么噪声坐标要每帧偏移

```glsl
noiseCoord += mod(float(frameCounter), 64.0) * 0.618;
```

（用 `mod()` 而不是 `%`：整数取模运算符 `%` 是 GLSL 1.30 才加入的，
`#version 120` 里不存在。）

如果每帧图案相同，静态画面上的噪点会被看成固定的脏点，
比色带还难看。每帧换个图案，人眼就会自动把它平均掉。

`% 64` 是为了防止 `frameCounter` 无限增大导致浮点精度丢失
（玩几个小时后画面会开始闪烁，就是这个原因）。

---

## 7. 暗角

```glsl
vec2 centered = (screenCoord - 0.5) * vec2(aspectRatio, 1.0);
float vignetteFactor = 1.0 - VIGNETTE * dot(centered, centered) * 2.0;
color *= vignetteFactor;
```

- `screenCoord - 0.5` 把原点移到屏幕中心
- 乘 `aspectRatio` 是为了让暗角在宽屏上保持**圆形而不是椭圆**
- `dot(v, v)` 就是距离的平方，比 `length()` 少一次开方

强度 `0.15` 是轻微、`0.4` 已经很明显。**别调太高**，
暗角过重会让画面显得脏。

---

## 8. 后处理管线小结

```
colortex0 ──┐
            ├─> 亮部提取 ─> colortex3 ─> 高斯模糊 ─> colortex4 ──┐
            │                                                    │
            └───────────────────> 相加 <─────────────────────────┘
                                    ↓
                              色调映射 + 调色
                                    ↓
                                 暗角
                                    ↓
                              gamma 编码
                                    ↓
                                 抖动
                                    ↓
                                屏幕输出
```

**顺序不是随便定的**，每一步都有理由：

| 顺序 | 理由 |
|------|------|
| 泛光在映射前 | 泛光是光，要和场景一起被压缩 |
| 调色在映射后 | 值域固定后调色才可预测 |
| gamma 在最后 | 它是"给显示器看"的转换 |
| 抖动在 gamma 后 | 色带产生于最终显示值 |
| 调试视图在最后 | 它要绕过所有处理 |

---

下一章：[`07-debugging-and-performance.md`](07-debugging-and-performance.md)
—— 出问题时怎么办。
