# 水体改进

水上观察时，水底保持原位置；水下观察时，水上景物随波浪扭动，水下前景保持稳定。当前版本通过景物运动区分水面两侧，水内颜色由光程吸收与散射产生。

## 水底采样

颜色与不透明深度始终使用原屏幕坐标，水内光程取水面与几何位置之间的视线距离。删除了折射射线求交、逐层限制、坐标回退与屏幕边缘收敛逻辑。波浪继续作用于水面法线、几何和倒影；聚光仍沿入水阳光方向投影。

`WATER_REFRACTION_STRENGTH` 保留配置标识以兼容已保存的设置，界面名称改为“水下波动强度”。它仅控制水下看向水面的轻微偏移。

## 水下界面

本地 Sildur 的 `composite1.fsh` 使用世界坐标的多层波动计算透射扰动，并按天光与天气调节焦散。本项目参考其动画锚定和日照约束，独立实现水面交点驱动的扰动与程序聚光纹理。

水内光程、视线方向和不透明几何的世界高度共同分类景物。水面交点决定波浪相位，水上物体与天空之间的轮廓可一起移动；只在水下前景附近渐退偏移。采样明确在真实纹素中心进行双线性插值，减少亚像素运动的跳变。

默认扰动上限为 1080p 下 6 像素，并随分辨率缩放。水下前景不接受扰动；界面不再叠加渐变水色或宽瓣环境反射。水内吸收、散射和光柱仍按各自光程计算。

这是有深度约束的屏幕空间透射近似，偏移区域无法恢复当前画面未记录的遮挡背面。

## 水上反射

默认粗糙度为 0.25，反射强度为 0.3。倒影采用透视正确的屏幕空间 DDA，允许背景进入粗糙滤波轮廓，排除明显更近的前景；部分清晰倒影过渡到当地散射。水的法向反射率保持约 2%。

## 水内光照

焦散由两层变形胞元形成不规则网纹，亮边采用连续高斯横截面。水深和浑浊度略微增加亮边宽度，像素足迹控制抗锯齿与远处衰减，保留近处聚光细节。默认强度为 0.35，受日照、遮挡、水深及接收面朝向控制。日照散射采用半分辨率固定八步积分，阴影在实际纹素中心比较后双线性插值。夜间和无天光洞穴跳过日照散射。

| 通道 | 职责 |
|---|---|
| `composite` | 半分辨率云；水下估计一次入水深度 |
| `composite1` | 半分辨率水下光柱与路径元数据 |
| `composite2` | 水体透射、反射、聚光、光柱与云合成 |
| `composite3` | 泛光亮部提取 |
| `composite4` | 泛光过滤 |

本轮未新增纹理附件或渲染通道。水上透射不再执行最多六十四步的折射 DDA；水下扰动只对穿过水面的景物执行。没有可靠的逐帧 GPU 性能对照，因此不报告 FPS 变化。

## 验证

回归检查要求水下波动开关对水上水底无影响，水下看向水上时具有可见扰动，且不改变水下前景。当前固定镜头、开关对照与结果见[可见性改进](23-visibility-stability.md)。

早期界面反射版本的记录保留在 `.preview/water-interface-v2-final/` 与 `.preview/water-interface-v2-checks/`；这些图像不代表当前的水下界面。

## 使用

同步光影后按 F3+R 重载，无需更换 Mod。“水下波动强度”设为零可关闭界面的采样偏移，水内吸收仍然生效。

## 来源

- [Sildur 官方说明与更新记录](https://sildurs-shaders.github.io/changelogs/)及本地 Sildur `shaders/composite1.fsh`：水下反射环境色与距离雾的分工。
- [PBRT 反射与透射](https://www.pbr-book.org/4ed/Reflection_Models/Specular_Reflection_and_Transmission)：水到空气界面随角度改变反射与透射。当前实现对该角度关系作宽过渡近似。
- Walter、Marschner、Li 与 Torrance（2007），[Microfacet Models for Refraction through Rough Surfaces](https://www.cs.cornell.edu/~srm/publications/EGSR07-btdf.pdf)：粗糙表面的反射与透射分布；本项目没有实现其完整模型。
- [NVIDIA 阴影抗锯齿](https://developer.nvidia.com/gpugems/gpugems/part-ii-lighting-and-shadows/chapter-11-shadow-map-antialiasing)：阴影比较结果的过滤。
- 用户提供的[海面渲染文章](https://bbs.csdn.net/weixin_42571444/article/details/100544715)与[水面及海洋渲染](https://www.plumephp.com/graphics-water-ocean-rendering/)：用于核对颜色、深度、反射与散射的工程分工。
