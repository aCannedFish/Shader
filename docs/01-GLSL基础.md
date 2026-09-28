# 01 · GLSL 基础

> 这一章只讲**这个光影用得到**的 GLSL。GLSL 的完整语法远不止这些，
> 但把下面这些吃透，你已经能读懂本项目 100% 的代码。
> 更全的语法速查见 [`09-参考速查表.md`](09-参考速查表.md)。

---

## 1. GLSL 是什么

GLSL（OpenGL Shading Language）是写给 GPU 的语言。它和 C 很像，但有三个
根本区别，理解这三点能省下大量困惑：

| | C / Java | GLSL |
|---|---|---|
| 什么时候执行 | 你调用它才执行 | **GPU 自动对每个顶点/每个像素各执行一次** |
| 能不能打印 | `printf` 调试 | **不能**。唯一的输出是"这个像素是什么颜色" |
| 数据从哪来 | 参数、全局变量 | 只能从**声明的关键字**进来（见第 5 节） |

第三点的推论：**GLSL 没有"主循环"**。你写的 `main()` 是一个"模板"，
GPU 会把它实例化几百万次同时跑。

### 顶点着色器 vs 片元着色器

本项目每个程序都是一对文件：

- **`.vsh` 顶点着色器**：每个**顶点**跑一次。一个方块 8 个顶点，
  一帧可能几十万次。负责"这个顶点在屏幕上的哪个位置"。
- **`.fsh` 片元着色器**：每个**像素**跑一次。一帧可能几亿次。
  负责"这个像素是什么颜色"。

因为执行次数差三个数量级，**能放在顶点阶段算的就别放在片元阶段算**。
本项目里波浪的顶点位移放在 `.vsh`、波浪法线放在 `.fsh`，
就是因为前者只需要每个顶点算一次，后者必须逐像素。

---

## 2. 类型

```glsl
float a = 1.0;        // 标量
int   b = 3;          // 整数
bool  c = true;

vec2 uv = vec2(0.5, 0.5);          // 两个 float
vec3 rgb = vec3(1.0, 0.5, 0.2);    // 三个 float
vec4 rgba = vec4(rgb, 1.0);        // 用 vec3 拼一个 vec4

mat3 rotation;   // 3x3 矩阵
mat4 mvp;        // 4x4 矩阵，本项目里几乎所有矩阵都是 mat4
sampler2D tex;   // 纹理句柄（只能声明，不能赋值）
```

### 三个必须记住的细节

**① 浮点数必须写小数点。**
`float a = 1;` 在多数驱动上会编译失败，必须写 `1.0`。
混用也不行：`1.0 * 2` 合法（整数会自动提升），但 `vec3 * 2` 不合法，
要写 `vec3 * 2.0`。

**② `uv` 是 vec2，采样要用 vec2。**
`texture2D(tex, vec3)` 是错的。

**③ 构造式可以任意混搭**，这是 GLSL 很好用的特性：

```glsl
vec4 color = vec4(vec3(1.0), 0.5);   // rgb 全 1，a = 0.5
vec4 p = vec4(someVec3, 1.0);        // 常用：给三维坐标补一个 w = 1，表示"点"
vec3 n = vec3(someVec2, 0.0);        // 常用：二维补零凑三维
mat3 r = mat3(gbufferModelView);     // 取 4x4 矩阵左上角的 3x3（只保留旋转）
```

---

## 3. 分量访问（swizzle）

```glsl
vec4 c = vec4(1.0, 0.5, 0.25, 1.0);

c.rgb       // -> vec3(1.0, 0.5, 0.25)   取前三个
c.a         // -> 1.0                     取第四个
c.xy        // -> vec2(1.0, 0.5)          等价于 rg
c.bgra      // -> 顺序可以任意重排
c.xx        // -> vec2(1.0, 1.0)          可以重复
```

`rgba`（颜色）和 `xyzw`（坐标）和 `stpq`（纹理）是三套等价写法，
**同一表达式里不能混用**（`c.rgzw` 不合法）。本项目的约定：

- 表示颜色时用 `rgb` / `a`
- 表示坐标时用 `xyz` / `w`
- 表示纹理坐标时用 `xy`

---

## 4. 函数与常用内置函数

自定义函数和 C 一样：

```glsl
// 返回类型  函数名(参数类型 参数名)
float    square(float x) { return x * x; }
vec3     shade(vec3 albedo, vec3 light) { return albedo * light; }
void     doNothing() { }
```

> **GLSL 120 要求"先定义后使用"**。函数 A 调用函数 B，B 必须写在 A 前面
> （或者提前写一行函数原型）。本项目把公共函数放在 `lib/` 里
> 并保证 `#include` 顺序正确，就是为了避免这个问题。

### 一定会用到的内置函数

| 函数 | 作用 | 本项目里的用处 |
|---|---|---|
| `mix(a, b, t)` | 线性插值 `a*(1-t) + b*t` | 混合雾色、插值光照 |
| `clamp(x, lo, hi)` | 夹到区间内 | 防止 N·L 为负 |
| `smoothstep(e0, e1, x)` | 平滑过渡（两端导数为 0） | 阴影距离淡出、昼夜过渡 |
| `step(edge, x)` | `x >= edge` 返回 1 否则 0 | 阴影的深度比较 |
| `dot(a, b)` | 点积 | **计算 N·L（光照的核心）** |
| `length(v)` | 向量长度 | 算到摄像机的距离 |
| `normalize(v)` | 单位化 | 把方向向量变成长度 1 |
| `max` / `min` | 大小比较 | 阈值、避免除零 |
| `pow(x, y)` | 幂 | 高光衰减、gamma |
| `exp(x)` | e 的 x 次方 | 高斯模糊权重、水下雾 |
| `sin` / `cos` | 三角函数 | 水面波浪 |
| `fract(x)` | 取小数部分 | 哈希随机数 |
| `floor` / `ceil` | 向下/向上取整 | 像素化效果 |
| `abs(x)` | 绝对值 | 调试可视化 |
| `reflect(I, N)` | 反射向量 | 水面反射（扩展用） |
| `refract(I, N, eta)` | 折射向量 | 水下折射（扩展用） |

### 三个容易踩的坑

**`normalize(vec3(0.0))` 会得到 NaN。**
NaN 进入光照计算后会传染，表现为整块屏幕变黑或闪烁，而且**极难定位**。
本项目的 `safeNormalize(v, fallback)` 就是为此准备的：

```glsl
// lib/common.glsl
vec3 safeNormalize(vec3 v, vec3 fallback) {
    float len = length(v);
    return len > EPSILON ? v / len : fallback;   // 长度接近 0 时用备用值
}
```

**`pow(负数, x)` 也是 NaN。**
`pow(x, 2.2)` 在 x 为负时结果是未定义的，所以本项目写
`pow(max(color, 0.0), vec3(1.0/2.2))`。

**整数除法会丢精度。**
`1/2` 是 `0`。要写 `1.0/2.0` 或 `float(1)/float(2)`。
本项目所有除法都保证至少一侧是浮点。

---

## 5. 流程控制

```glsl
if (condition) { ... } else if (...) { ... } else { ... }

for (int i = 0; i < 4; i++) { ... }     // 上界必须是编译期常量
```

**GLSL 120 的限制**（比现代 GLSL 严）：

- 循环的上界**必须是常量表达式**，不能是 uniform 或变量。
  所以本项目的 PCF 循环写成 `for (int x = -SHADOW_SOFTNESS; ...)`，
  `SHADOW_SOFTNESS` 是 `#define`，在编译前就被替换成了数字。
- **没有 `switch`**。
- **没有数组初始化列表**（`float a[3] = {1,2,3};` 不合法）。

### `discard`：唯一能"提前退出"的方式

```glsl
if (albedo.a < alphaTestRef) discard;   // 这个像素不要了
```

`discard` 会丢弃当前像素，它不写颜色也不写深度。
树叶的镂空、雨的条纹靠它实现。

⚠️ `discard` 会让 GPU 无法使用"早期深度测试"优化，
所以**能用 alpha 混合就别用 discard**。本项目只在必须的地方用它。

---

## 6. 数据从哪来：attribute / uniform / varying

这是 GLSL 里最需要建立直觉的部分。三种限定符对应三种完全不同的数据源：

### `attribute` —— 每个顶点自己的数据（只有 `.vsh` 能用）

```glsl
vec4 position = gl_Vertex;   // 当前顶点的模型空间位置
vec3 normal = gl_Normal;     // 当前顶点的法线
vec4 color = gl_Color;       // 当前顶点的颜色
```

本项目使用 GLSL 120 兼容配置，所以基础顶点属性通过这些内置变量读取。
`mc_Entity` 一类自定义属性仍需用 `attribute` 声明。
**每个顶点都不一样**，所以它在片元阶段会被插值。

### `uniform` —— 整个绘制调用里所有人都一样的数据

```glsl
uniform mat4 gbufferModelView;   // 所有顶点共享同一个矩阵
uniform vec3 cameraPosition;     // 所有像素看到的是同一个摄像机位置
uniform sampler2D texture;       // 所有像素采样同一张贴图
```

`uniform` 由 CPU（游戏 / OptiFine）在绘制前设置好，着色器里**只读**。
本项目所有 uniform 都集中声明在 `lib/uniforms.glsl`，
方便你查阅"到底有哪些数据可用"。

### `varying` —— 顶点着色器的输出，片元着色器的输入

```glsl
// .vsh 里
varying vec2 vTexCoord;
void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}

// .fsh 里（声明必须与 .vsh 完全一致）
varying vec2 vTexCoord;
void main() {
    texture2D(texture, vTexCoord);   // 每个像素读一次
}
```

**关键理解：varying 会被自动插值。**

```
顶点 A (uv = 0,0)  ●───────────────●  顶点 B (uv = 1,0)
                          ↑
              这里的片元拿到的 uv 是 (0.5, 0)
```

GPU 会按像素到三个顶点的距离做加权平均。
这就是为什么贴图能正确铺在三角形上、颜色能平滑渐变 ——
**不是代码里写了插值，而是硬件自动做的**。

本项目把所有 varying 声明集中在 `lib/varyings.glsl`，
让 `.vsh` 和 `.fsh` 都 `#include` 同一份，避免两边写得不一致。

---

## 7. 纹理采样

```glsl
uniform sampler2D texture;      // 声明一个纹理（名字由 OptiFine 决定绑什么）
vec4 color = texture2D(texture, uv);   // 采样：给坐标，拿颜色
```

要点：

- 坐标范围是 `[0,1]`，**超出范围的行为取决于纹理的寻址模式**
  （重复 / 夹紧 / 镜像）。本项目为了保险会在采样前 `clamp`。
- `texture2D` 是 GLSL 120 的函数名。GLSL 330 之后改叫 `texture`。
  **本项目统一用 120 的写法**，看到 `texture2D` 不要觉得奇怪。
- 常用的固定绑定名（OptiFine 负责绑定）：
  `texture`（方块图集）、`lightmap`（光照贴图）、`shadowMap`（阴影贴图）、
  `colortex0`~`colortex15`（渲染目标）、`depthtex0`（深度）、`noisetex`（噪声）。

---

## 8. 预处理指令

GLSL 的预处理器和 C 一样，本项目的可配置性完全建立在它之上。

```glsl
#include "/lib/common.glsl"       // 文本包含，路径以光影包根目录为起点

#define PI 3.14159265             // 定义宏
#define ENABLE_SHADOWS 1

#ifndef SETTINGS_GLSL             // 没定义过就执行下面
#define SETTINGS_GLSL             // 头文件保护：防止重复包含
#endif

#if TONEMAP_MODE == 1
    color = tonemapACES(color);
#elif TONEMAP_MODE == 2
    color = tonemapReinhard(color);
#else
    color = clamp(color, 0.0, 1.0);
#endif
```

**为什么大量用宏而不是 `if`？**
宏在**编译前**就被替换掉了，编译器看到的是已经剪枝后的代码。
关掉一个功能，相关代码会**彻底消失**，连寄存器都不会占用。
如果用 `if (ENABLE_SHADOWS == 0)` 这种运行时判断，
分支两边的代码都要编译进去，还会带来分支开销。

本项目的 `settings.glsl` 里所有开关都是宏，
在游戏内改动它们时会让光影**重新编译**（所以会卡一下），这是正常的。

---

## 9. 一段最小但完整的样例

把这一章的内容串起来，这就是一个能编译、能跑的最小片元着色器：

```glsl
#version 120                                  // 必须第一行

#include "/settings.glsl"                    // 设置（含所有开关）
#include "/lib/uniforms.glsl"                 // uniform 声明

uniform sampler2D texture;                    // 方块图集
uniform sampler2D lightmap;                   // 光照贴图

varying vec2 vTexCoord;                       // 从顶点着色器插值而来
varying vec4 vColor;
varying vec2 vLightmapCoord;

void main() {
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;   // 材质颜色
    if (albedo.a < alphaTestRef) discard;                   // 镂空

    vec3 lightColor = texture2D(lightmap, vLightmapCoord).rgb;
    vec3 color = albedo.rgb * lightColor;                   // 最原始的光照

    gl_FragData[0] = vec4(color, albedo.a);                 // 输出
}
```

对照 `shaders/gbuffers_terrain.fsh` 会发现，本项目的实现比这复杂得多，
但每一步都能在上面找到影子 —— **多出来的部分是精度、是柔和度、
是给人看的观感，而不是新的原理**。

---

下一章：[`02-着色器管线与程序类型.md`](02-着色器管线与程序类型.md)
—— 这些 `.vsh` / `.fsh` 到底什么时候被执行，谁先谁后。
