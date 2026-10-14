# 03 · 坐标系与空间变换

> 光影里 80% 的 bug 都是"坐标用错了空间"。
> 这一章把每个空间、每个矩阵、每一次变换的理由讲清楚。
> 对照代码读：[`lib/space.glsl`](../shaders/lib/space.glsl)。

---

## 1. 为什么需要这么多"空间"

同一个点，在不同坐标系里有不同的数值：

- 你现在所在的房间：相对**你自己**是"前方 2 米"
- 相对**房子**是"客厅东墙边"
- 相对**地球**是"北纬 39°，东经 116°"

三种说法指的是同一个位置，只是**参考系**不同。
图形学里也一样，而且每一步变换都解决一个具体问题：

| 空间 | 原点在哪 | 解决什么问题 |
|------|---------|------------|
| **世界空间** World | 世界原点 | 物体在世界里的绝对位置 |
| **视图空间** View | 摄像机 | "在我前面还是后面？左边还是右边？" |
| **裁剪空间** Clip | — | 投影后准备做透视除法 |
| **NDC** | 屏幕中心 | 归一化到 `[-1,1]`，与分辨率无关 |
| **屏幕空间** Screen | 左下角 | 最终像素坐标 `[0,1]` |

---

## 2. 三次变换，三个矩阵

```
世界空间 ──gbufferModelView──> 视图空间 ──gbufferProjection──> 裁剪空间
                                                                  │ ÷w
                                                                  ↓
                                                              NDC [-1,1]
                                                                  │ ×0.5+0.5
                                                                  ↓
                                                              屏幕 UV [0,1]
```

### 第一步：模型 → 视图

作用：把摄像机"搬到"原点，并且让它朝向 `-Z`（OpenGL 的约定）。

```glsl
vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
```

变换之后：
- 摄像机永远在 `(0, 0, 0)`
- `-z` 是正前方，`+x` 是右，`+y` 是上
- **到摄像机的距离 = `length(viewPos.xyz)`** ← 雾和阴影淡出都用它

最后这点非常重要，也是本项目到处用 `length(vViewPos)` 的原因：
在视图空间里算距离不需要任何额外信息。

### 第二步：视图 → 裁剪

```glsl
gl_Position = gl_ProjectionMatrix * viewPos;
```

透视投影矩阵做两件事：

1. **近大远小**：远处的顶点被拉向屏幕中心
2. **把距离塞进 `w` 分量**：`w` 变换后等于"到摄像机的深度"

`gl_Position` 是四维的 `(x, y, z, w)`。GPU 接下来会自动做**透视除法**：

```
ndc = gl_Position.xyz / gl_Position.w
```

这一步**你不需要写**，是硬件自动做的。除法之后得到 NDC：
`x, y ∈ [-1, 1]` 是屏幕范围，`z ∈ [-1, 1]` 是深度。

### 第三步：NDC → 屏幕 UV

```glsl
vec2 uv = ndc.xy * 0.5 + 0.5;      // [-1,1] -> [0,1]
```

这一步**只有需要采样纹理时才要自己写**（比如阴影贴图、后处理）。

---

## 3. 反向变换

反向矩阵是正向矩阵的逆，OptiFine 也直接提供：

| 正向 | 反向 | 用途 |
|------|------|------|
| `gbufferModelView` | `gbufferModelViewInverse` | 视图 → 世界 |
| `gbufferProjection` | `gbufferProjectionInverse` | 裁剪 → 视图 |

```glsl
// 视图空间 -> 世界空间（摄像机相对）
vec3 worldPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;

// 视图空间 -> 绝对世界坐标
vec3 absolutePos = worldPos + cameraPosition;
```

### ⚠️ 最容易搞混的一点：两种"世界空间"

Minecraft 的坐标有两个版本，本项目的注释里严格区分：

| 名字 | 原点是 | 怎么得到 |
|------|-------|---------|
| **摄像机相对世界坐标** | 摄像机 | `gbufferModelViewInverse * viewPos` |
| **绝对世界坐标** | 世界原点 | 上面的结果 `+ cameraPosition` |

**什么时候必须用绝对坐标？**

只要你要的效果需要"固定在世界上的某个位置"，就必须用绝对坐标。
本项目的水面波浪就是例子：

```glsl
// lib/water.glsl 的正确用法
vec3 playerPos = (gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex).xyz;
vec2 worldXZ = (playerPos + cameraPosition).xz;
```

```glsl
// 错误示范
vec2 worldXZ = gl_Vertex.xz;   // 只得到模型空间坐标，区块之间可能重复
```

原理：`gl_Vertex` 对地形来说是区块内的模型空间位置。
先用当前对象的模型视图矩阵变到视图空间，再转回摄像机相对世界坐标，
最后加摄像机位置，波峰才能稳定落在世界的同一位置。

---

## 4. 法线怎么变换

法线**不能用位置矩阵直接变换**（位移部分会污染它），
要用左上角 3×3 的旋转部分：

```glsl
vNormalView = gl_NormalMatrix * gl_Normal;
```

`gl_NormalMatrix` 是当前模型视图矩阵左上角 3×3 的逆转置，
还可以正确处理非均匀缩放。

### 为什么法线必须归一化

变换过程和 varying 插值都可能改变向量长度，
而 `dot(N, L)` 的正确性依赖 N 是单位向量：

```glsl
vNormalView = normalize(gl_NormalMatrix * gl_Normal);
```

### ⚠️ 更隐蔽的坑：零向量

粒子、信标的顶点法线**可能是 `(0,0,0)`**。
`normalize(vec3(0.0))` 会得到 NaN，而 NaN 一旦进入光照计算就会传染，
现象是**整块屏幕变黑或疯狂闪烁**，且极难定位。

所以本项目统一用 `safeNormalize`：

```glsl
vNormalView = safeNormalize(gl_NormalMatrix * gl_Normal, vec3(0.0, 0.0, 1.0));
                                    // ↑ 长度为 0 时回退到"朝向摄像机"
```

---

## 5. 深度：为什么不能直接用

`depthtex0` 里存的深度**不是线性距离**。

透视投影后，深度值的分布是这样的：

```
depth = 0.0 ──────────────────────────────── depth = 1.0
        │              │        │     │  │ │││
       近平面        10格     50格  100格  ...
       ↑ 精度极高                    ↑ 精度极低（相邻两个深度值差好几个方块）
```

这是浮点精度的必然结果（远处被压缩到很窄的区间），
也是 `z-fighting`（两块面争夺同一深度）的根源。

### 还原成线性距离

```glsl
// lib/space.glsl
float linearizeDepth(float depth) {
    float ndcDepth = depth * 2.0 - 1.0;                            // [0,1] -> [-1,1]
    return (2.0 * near * far) / (far + near - ndcDepth * (far - near));
}
```

这个公式来自"把 NDC 深度代回投影矩阵的逆"。
**做任何屏幕空间效果（SSAO、景深、体积光）的第一步都是它。**

### 从屏幕坐标还原三维位置

```glsl
// lib/space.glsl
vec3 screenToView(vec2 uv, float depth) {
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos = gbufferProjectionInverse * ndc;
    return viewPos.xyz / viewPos.w;      // 别忘了透视除法
}
```

注意最后的 `/ viewPos.w`：投影矩阵的逆恢复出来的是"齐次坐标"，
必须自己再做一次透视除法。**漏掉它会得到位置完全错误的结果**
（画面看起来像被拉伸过）。

---

## 6. 阴影的坐标系

阴影贴图有**自己的一套矩阵**，因为它的摄像机是太阳：

| 玩家摄像机 | 太阳摄像机 |
|-----------|-----------|
| `gbufferModelView` | `shadowModelView` |
| `gbufferProjection` | `shadowProjection` |

### 完整的阴影坐标计算

```glsl
// 1. 视图空间 -> 世界空间（因为 shadowModelView 接受世界坐标）
vec4 worldPos = gbufferModelViewInverse * viewPos;

// 2. 世界空间 -> 太阳的裁剪空间
vec4 shadowClipPos = shadowProjection * shadowModelView * worldPos;

// 3. 畸变（顶点和片元必须完全一致，见下）
shadowClipPos.xyz = distortShadow(shadowClipPos.xyz);
```

⚠️ **第 1 步不能省**。最常见的错误就是写成：

```glsl
vec4 shadowClipPos = shadowProjection * shadowModelView * viewPos;   // ❌ 错
```

`shadowModelView` 的输入是**世界空间**坐标，而 `viewPos` 是视图空间坐标。
两者差着一个摄像机变换，结果就是阴影整体平移到一个完全错误的位置。

### 畸变（distortion）

阴影贴图是**正交投影**，覆盖以玩家为中心、边长为 `2 × shadowDistance`
的正方形。问题在于：一个纹素在贴图中心覆盖的实际面积小（精度高），
在边缘覆盖的实际面积大（精度低）。

`distortShadow()` 把裁剪空间坐标按到中心的距离向外拉伸：

```glsl
vec3 distortShadow(vec3 clipPos) {
    float dist = length(clipPos.xy);
    float factor = (1.0 - SHADOW_MAP_BIAS) + dist * SHADOW_MAP_BIAS;
    clipPos.xy /= factor;
    return clipPos;
}
```

效果相当于把纹素重新分配：**近处多分一些，远处少分一些**。

`SHADOW_MAP_BIAS = 0.0` 表示不畸变，`0.9` 是常用值；1.0 会让径向坐标退化。

⚠️ **顶点着色器和片元着色器必须调用完全相同的畸变函数**。
两边只要有一点不一致，投影位置和采样位置就对不上，阴影会整体错位。
本项目把它放在 `lib/space.glsl` 里两边共用，就是为了杜绝这个风险。

### 畸变的位置

```glsl
// gbuffers 顶点阶段：传递未畸变的线性投影坐标。
vShadowClipPos = shadowClipPos;

// gbuffers 片元阶段：先插值和透视除法，再计算非线性畸变。
vec3 shadowClip = vShadowClipPos.xyz / vShadowClipPos.w;
vec3 shadowUv = distortShadow(shadowClip) * 0.5 + 0.5;
```

径向畸变是非线性函数，先畸变顶点再插值会改变实际接收点的位置。当前接收路径在片元阶段施加畸变。阴影投射通道仍在顶点阶段畸变并交给 GPU 光栅化；当前日月阴影采用正交投影，w 为 1。该有限分辨率光栅化仍存在近似误差，需要接收面补偿和受限深度偏移。

---

## 7. 屏幕空间与 `gl_FragCoord`

在后处理程序里，`gl_FragCoord` 直接给出**当前像素的像素坐标**
（原点是屏幕左下角，单位是像素），`z` 分量是该像素的深度。

```glsl
vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
```

**为什么不用插值出来的 UV？**
因为全屏四边形的纹理坐标约定在不同加载器/驱动上可能上下翻转，
而 `gl_FragCoord` 永远是对的。少一个 varying 也少一次插值。

⚠️ **注意分辨率**：`viewWidth` / `viewHeight` 是**渲染分辨率**，
可能和窗口分辨率不同（游戏里开了"渲染倍数"时）。
用它们做归一化才能得到正确的 `[0,1]` 坐标。

---

## 8. 调试坐标问题的标准流程

遇到"位置不对"的问题，按这个顺序排查：

1. **打开调试视图看视图空间坐标**
   `settings.glsl` 里设 `DEBUG_VIEW 6`。
   正常画面：屏幕中心偏蓝（-Z 方向），左右红/青，上下绿/紫。
   如果整屏一个颜色，说明坐标还原坏了。

2. **检查是不是漏了 `gbufferModelViewInverse`**
   症状：效果整体平移一个摄像机距离，或者跟着摄像机旋转。

3. **检查是不是把两种世界空间混用了**
   症状：效果跟着玩家移动（该固定的没固定）。

4. **检查法线**
   `DEBUG_VIEW 1`。朝上的面应该是**绿色**（`+y`）、
   朝右是**红色**（`+x`）、朝向摄像机是**蓝色**（`+z`）。
   如果颜色分布和实际朝向对不上，说明法线变换用错了矩阵。

5. **检查 `w` 分量**
   只要做过投影矩阵的逆变换，就必须记得除以 `w`。

---

下一章：[`04-lighting-model.md`](04-lighting-model.md)
—— 有了正确的坐标，接下来算颜色。
