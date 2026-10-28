#!/usr/bin/env python3
"""Generate and validate the complete configuration reference from shader settings."""

import argparse
from decimal import Decimal
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DESCRIPTIONS = {
    'RAIN_PUDDLES_STRENGTH': '露天地表湿润与局部积水强度，随湿度积累并在雨后逐渐消退；墙面、植被和低天光地表不积水。积水独立于普通材质反射开关，复用其采样预算，0 关闭。',
    'ENABLE_REALISTIC_RAIN': '窄雨丝与下落短滴开关，复用游戏雨雪网格的范围和遮挡；0 恢复原版雨纹。雨层统一在云雾之后合成。',
    'ENABLE_RAIN_PUDDLES': '露天地表湿润水膜与反射积水开关；依据原生天光和表面朝向近似积水区域，不改变世界几何。',
    'RAIN_RIPPLE_STRENGTH': '水面与积水中的雨滴扩散圆环强度，使用世界坐标解析斜率并过滤远处细节；0 关闭。',
    'RAIN_FOG_STRENGTH': '雨天森林和山坡的局部体积雾强度，随降雨平滑变化，受真实地表高度和天空暴露约束；需要配套 Mod 的地表缓存，0 关闭雨雾。',
    'ORE_GLOW_STRENGTH': '原矿中矿物像素的自发光强度，煤矿及周围石头保持原有受光；0 关闭。由配套 Mod 按当前资源包计算遮罩，不增加方块光照等级或真实局部光源。支持边长为 64 的约数且不大于 64 的静态正方形矿石贴图。',
    'GROUND_FOG_STRENGTH': '沿真实地表分布的林地与山坡薄雾，晨昏、夜间及雨天较明显；近处渐退，单层最多遮蔽 55%，0 停止积分。需要当前配套 Mod 的地表缓存。',
    'GROUND_FOG_HEIGHT': '地面雾的基准垂直衰减尺度（方块），随地形与低频噪声变化；不是固定世界高度。',
    'ATMOSPHERE_STEPS': '地面雾及下界、末地近景烟霭的积分步数，复用体积场分辨率；不影响水下光学。',
    'AURORA_STRENGTH': '主世界晴夜的上层大气发光幕强度，北侧较明显，受暮光、月光、降雨与云遮挡限制；0 关闭。',
    'AURORA_SPEED': '极光缓慢起伏的速度；0 冻结运动，周期与加载器一小时计时回绕一致。',
    'AURORA_STEPS': '天空缓存中极光发光层的积分步数，不逐全屏像素计算。',
    'TWILIGHT_STRENGTH': '日出日落的暖色地平线、背日粉紫色带、表面半球环境和云层间接光，0 关闭新增晨昏项。',
    'NETHER_ATMOSPHERE': '保留生物群系雾色的低处暖色调与非均匀烟霭，已有 GI 在近处提供柔和局部光晕；0 关闭新增部分。',
    'END_ATMOSPHERE': '末地的缓慢星云、冷色半球填充及稀薄局部辉光，0 恢复基础虚空环境。',
    'ENABLE_MATERIAL_REFLECTIONS': '按方块分类启用导体、抛光介质、晶体和玻璃模型；包括日月与配套点光高光、单次屏幕反射及环境回退，关闭后恢复原有漫反射。',
    'MATERIAL_REFLECTION_STRENGTH': '方块材质的反射与漫反射能量分配倍率；0 恢复原有漫反射，水面使用独立参数。',
    'MATERIAL_REFLECTION_STEPS': '方块、玻璃和积水屏幕空间反射的最大步数，命中后另做十次二分细化；光线覆盖整个渲染距离，步数较少时更易跳过细小物体。不控制水面反射。',
    'NETHER_AMBIENT': '下界固定的暖色环境光强度，随生物群系雾色轻微染色，不随日夜变化；局部光与 GI 独立叠加。',
    'END_AMBIENT': '末地固定的冷紫色半球环境光强度，不随日夜变化；局部光与 GI 独立叠加。',
    'NETHER_FOG_DENSITY': '下界按距离的消光系数，随当地生物群系雾色渐变并在加载边界收敛；同时受全局雾浓度调节。',
    'END_FOG_DENSITY': '末地按距离的紫色薄雾消光系数，并在加载边界收敛；同时受全局雾浓度调节。',
    'MIN_AMBIENT_LIGHT': '所有几何表面的最低环境亮度，独立于日月和天光；保留朝向与接触明暗，0 关闭。',
    'ENABLE_LENS_FLARE': '太阳镜头光晕开关，受圆盘可见度和实际亮度控制。',
    'LENS_FLARE_STRENGTH': '太阳镜头鬼影与细窄星芒的强度，0 关闭。',
    'ENABLE_CHROMATIC_ABERRATION': '轻度径向色差开关，中心保持清晰。',
    'CHROMATIC_ABERRATION_STRENGTH': '以 1080p 为参考的角落单侧通道像素偏移，0 关闭。',
    'FOLIAGE_TRANSLUCENCY': '树叶、草木和庄稼的日月逆光透射强度；仅薄植被投影体透光，实体墙和厚叶团截止，0 关闭。',
    'VOLUMETRIC_RESOLUTION': '体积云、空气散射、地面雾、维度烟霭和水下光柱的内部视口：0 四分之一，1 二分之一。四分之一将体积片元数降至默认的约 1/4，保留深度感知重建，场景本体分辨率不变。',
    'AIR_SCATTER_STEPS': '近地面日光散射的固定距离区间数；每区间执行两次过滤阴影查询。较低值节省开销，较高值改善细光束采样。',
    'WATER_SHAFT_STEPS': '水下日照光柱的固定积分步数；不影响水底焦散纹理。',
    'AIR_SCATTER_STRENGTH': '近地面日光散射与丁达尔光束强度；低角度阳光较明显，受空间密度、遮挡与浑浊度控制，0 关闭。',
    'ENABLE_SHADOWS': '日月阴影总开关；0 关闭采样，1 开启。',
    'SHADOW_SOFTNESS': '方向光阴影质量：0 单点，1 为 5 点遮挡搜索和 8 点过滤，2 为 9 点搜索和 12 点过滤；半影随遮挡距离增大，无遮挡时提前结束。',
    'SHADOW_MAP_BIAS': '日月阴影纹素向近景集中的畸变强度；不要设置为 1。',
    'SHADOW_BIAS': '深度比较偏移；增大可缓解条纹，过大可能造成阴影脱离物体。',
    'shadowMapResolution': '日月阴影贴图边长（像素）；越大边缘越清晰，阴影阶段带宽与显存随平方增长。',
    'shadowDistance': '日月阴影覆盖距离（方块）；越大远处阴影越多，同分辨率下越糊，阴影阶段几何量随之增加。',
    'AMBIENT_STRENGTH': '天空、暗部基础光与最低环境项倍率，局部点光单独控制。',
    'SUNLIGHT_STRENGTH': '太阳直射强度。',
    'MOONLIGHT_STRENGTH': '月光直射强度，独立于太阳并受月相影响。',
    'NIGHT_AMBIENT_STRENGTH': '夜间最低环境光，按当地天光减弱；不直接照亮封闭洞穴。',
    'NIGHT_EXPOSURE': '夜间暗部曝光上限，明亮区域的增益逐渐回到 1，减少光源过曝。',
    'SKY_TINT': '环境光采用天空颜色的混合比例。',
    'BLOCK_LIGHT_STRENGTH': '火把等局部光强度；同时影响 Mod 求解，应等待重新收敛。',
    'BLOCK_LIGHT_FALLOFF': '原版局部光按传播等级换算方块距离后的平方衰减倍率；6 为基础校准，较大值使外围更暗。',
    'SMOOTH_BLOCK_LIGHT': '平滑原版传播光照采样，不模糊材质纹理。',
    'ENABLE_COLOURED_LIGHTING': '彩色光照总开关：开启时方块光按光源色调染色（覆盖已加载区域，需配套 Mod），彩色玻璃给日月阴影与点光染色，发光方块以自身颜色照亮其投影；关闭时统一使用原版暖色方块光和无色阴影。',
    'FOG_DENSITY': '加载距离雾浓度，并参与水下光程衰减倍率。',
    'UNDERWATER_MIN_VISIBILITY': '保留附近物体的最低环境亮度，并限制近处雾遮蔽；不恢复已吸收的颜色，远景继续衰减。',
    'WATER_CAUSTICS_STRENGTH': '受日照、遮挡、水深和表面朝向控制的焦散强度，0 关闭；双尺度变形聚光网与柔和亮边。',
    'UNDERWATER_SHAFT_STRENGTH': '水下阳光散射强度；沿视线积分真实日照遮挡与水内吸收，以双瓣前向散射形成随视角变化的光束。0 跳过积分。',
    'UNDERWATER_DENSITY': '水下按光程的吸收和散射倍率。',
    'UNDERWATER_DEPTH_DIMMING': '随相机浸入深度调整蓝色基调与天空散射，同时控制光柱入射光程的衰减。',
    'WATER_SURFACE_OPACITY': '水上观察时的水色遮蔽强度，随水内光程累积；浅水保留水底，深水以水色和倒影为主。不改变水下相机的可见距离。',
    'WATER_TURBIDITY': '水体浑浊度，作用于水面透射和水下光程衰减。',
    'WATER_ABSORPTION': '波长相关吸收强度，水内光程较长时颜色变化更明显。',
    'WATER_REFRACTION_STRENGTH': '水上折射水底与水下出射方向的强度；水上按折射率求水底交点，水下由介质 Fresnel 形成约97度的折射窗口。0 关闭采样偏移，保留全反射。',
    'ENABLE_WATER_TEXTURE': '0 去掉水面贴图纹理，1 保留原版纹理；波浪另行控制。',
    'ENABLE_WATER_WAVES': '水面风浪位移与法线扰动开关；落雨圆环由落雨涟漪强度独立控制。',
    'WATER_COLOR_LIGHTNESS': '水体线性散射色从暗青向较明亮青色的混合比例，同时调整吸收颜色；保留少量群系差异，水面观感主要来自倒影。',
    'WATER_ROUGHNESS': '日月高光与水上倒影的粗糙度；较大值减少清晰镜面反射。',
    'WATER_REFLECTION_STRENGTH': '水上环境倒影和日月高光的整体倍率；Fresnel 参考 Sildur，正面约 5%，掠射时接近全反射，夜晚与雨天水面随天空变暗、变灰。',
    'WATER_REFLECTION_CLOUDS': '倒影中的体积云：0 查 deferred 每帧预建的云环境表，1 逐像素步进体积云，细节更多、成本更高。',
    'WATER_REFLECTION_STEPS': '水面屏幕空间倒影每条光线的最大步数；命中后另有十次二分细化。光线覆盖整个渲染距离，步数较少时步长按比例放宽，更易跳过细小物体。',
    'REFLECTION_OCCLUSION_STEPS': '水面与材质倒影沿阴影贴图步进 24 格的次数，另有五次二分细化。找出桥底、树冠下方、树影里的山坡等相机看不到的遮挡，遮挡点明显更近时取代屏幕命中；被挡住的面用环境光着色。0 关闭并退回天光衰减。',
    'WATER_SPECULAR_STRENGTH': '日月直接镜面高光的额外倍率。',
    'WATER_REFLECTION_BRIGHTNESS': '水上反射图像的亮度倍率，不改变倒影中的物体色相。',
    'ENABLE_FOLIAGE_WIND': '植被位移总开关，同时作用于日月阴影。',
    'WIND_STRENGTH': '植被风摆总幅度倍率。',
    'WIND_SPEED': '植被风摆时间速度倍率。',
    'LEAF_SWAY_STRENGTH': '树叶基础位移幅度，单位为方块。',
    'PLANT_SWAY_STRENGTH': '草木与庄稼基础位移幅度，根部权重为零。',
    'TONEMAP_MODE': '0 截断输出，1 使用 ACES 近似亮度曲线，2 使用 Reinhard 亮度曲线；中间调保持色相，高光压缩到显示色域。',
    'EXPOSURE': '日常 HDR 曝光倍率，夜间再乘夜间曝光。',
    'SATURATION': '最终饱和度，1 保持原值。',
    'CONTRAST': '以线性中灰 0.18 为锚点调整亮度对比，1 保持原值；暗部连续变化。',
    'VIGNETTE': '屏幕边缘暗角强度，0 关闭。',
    'ENABLE_BLOOM': '泛光亮部提取开关。',
    'BLOOM_THRESHOLD': '泛光的 HDR 亮度阈值，使用柔和过渡保留邻近亮部。',
    'BLOOM_STRENGTH': '泛光叠加到最终画面的倍率。',
    'BLOOM_RESOLUTION': '0 半分辨率，1 全分辨率；只缩放泛光视口，不影响场景分辨率。先提取亮部再降采样，避免吞掉细小光源。',
    'BLOOM_RADIUS': '可分离高斯泛光的半径倍率，两道过滤各使用 7 次线性采样；半径按场景像素定义，不随泛光档位改变。',
    'ENABLE_DITHER': '显示编码前添加轻微抖动以减小色带。',
    'DEBUG_VIEW': '0 正常，1 法线，2 光照贴图，3 阴影，4 深度，5 泛光，6 重建视图坐标。',
    'SKY_HAZE': '大气浑浊程度，主要影响 Mie 散射与日月附近光晕。',
    'SKY_EXPOSURE': '天空辐射亮度倍率。',
    'SKY_SAMPLES': '天空 LUT 的积分采样数，增大提高精度并增加成本。',
    'CELESTIAL_SIZE': '日月圆盘角度大小倍率，1 近似原版可见亮部。',
    'CLOUD_QUALITY': '0 为 24/2、1 为 40/3、2 为 64/5 次视线/光照采样；反射使用固定低预算。',
    'CLOUD_COVERAGE': '天气场中的云覆盖比例。',
    'CLOUD_DENSITY': '体积云密度倍率。',
    'CLOUD_BRIGHTNESS': '体积云散射辐射的亮度倍率。',
    'CLOUD_HEIGHT': '云层基准底部高度，单位为方块；局部底部随天气场起伏。',
    'CLOUD_THICKNESS': '云层基准厚度，单位为方块；局部厚度随天气场变化。',
    'CLOUD_SIZE': '云团与天气场的主要水平尺度，单位为方块。',
    'CLOUD_SPEED': '云层平移速度，0 静止；风向固定。',
    'CLOUD_SHADOW_STRENGTH': '地面日月直射受云影衰减的混合比例。',
    'CLOUD_NIGHT_BRIGHTNESS': '夜间云环境散射倍率，并结合月相。',
    'ENABLE_COMPANION_LIGHTING': '使用配套 Mod 的局部阴影和辐射体积；无有效数据时自动回退。',
    'ENABLE_LOCAL_SHADOWS': '是否在表面局部直射中使用独立阴影；GI 仍使用遮挡求解。',
    'LOCAL_LIGHT_COUNT': '活动点光源数量上限；范围内超额光源按影响筛选。',
    'LOCAL_LIGHT_RADIUS': '最高发光等级的局部照明半径，较低等级按比例缩放，单位为方块。',
    'LOCAL_SHADOW_RESOLUTION': '每个立方体阴影面的像素边长；六面图集成本随平方增长。',
    'LOCAL_SHADOW_UPDATES': '每次渲染线程更新处理的光源数量。',
    'LOCAL_SHADOW_SOFTNESS': '独立阴影 PCF 偏移倍率。',
    'LOCAL_SHADOW_STRENGTH': '独立阴影与完全受光结果的混合比例。',
    'LIGHTING_UPDATE_INTERVAL': '客户端方块场景重新采集间隔，单位为秒。',
    'GI_BOUNCES': '漫反射次数，0 关闭 GI，最多 6 次。',
    'GI_QUALITY': '局部体素 GI 每帧传播次数：0 关闭，1、2、3 分别执行对应次数；提高可加快移动与编辑后的收敛。独立于彩色光照开关。',
    'GI_MULTIBOUNCE': '允许间接光在受光表面继续反射；0 只保留直接照明产生的首次漫反射。',
    'GI_VOLUME_SIZE': '辐射体积边长，单位为方块；体素成本随立方增长。',
    'GI_PROPAGATION_STEPS': '每次反弹的传播步数。',
    'GI_WORK_PER_FRAME': '每次渲染线程更新允许的 GI 工作量，增大可加快收敛。',
    'GI_STRENGTH': '表面接收已完成间接光场的强度倍率。',
    'GI_REFLECTANCE': '材质反照率之外的反弹能量保留比例，较大值可增加溢色。',
}
MOD_OPTIONS = {
    'ORE_GLOW_STRENGTH',
    'GROUND_FOG_STRENGTH', 'GROUND_FOG_HEIGHT', 'RAIN_FOG_STRENGTH',
    'ENABLE_COMPANION_LIGHTING', 'ENABLE_LOCAL_SHADOWS', 'LOCAL_LIGHT_COUNT',
    'LOCAL_LIGHT_RADIUS', 'LOCAL_SHADOW_RESOLUTION', 'LOCAL_SHADOW_UPDATES',
    'LOCAL_SHADOW_SOFTNESS', 'LOCAL_SHADOW_STRENGTH', 'LIGHTING_UPDATE_INTERVAL',
    'GI_BOUNCES', 'GI_VOLUME_SIZE', 'GI_PROPAGATION_STEPS', 'GI_WORK_PER_FRAME',
}
PROFILES = ('LOW', 'MEDIUM', 'HIGH', 'ULTRA')


def language(path):
    """Read localized labels without treating comments as property entries."""
    result = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            result[key.strip()] = value.strip()
    return result


def configuration():
    """Validate every exposed option and collect exact defaults and allowed values."""
    settings = (ROOT / 'shaders/settings.glsl').read_text()
    properties = (ROOT / 'shaders/shaders.properties').read_text()
    labels = {code: language(ROOT / f'shaders/lang/{code}.lang')
              for code in ('zh_CN', 'en_US')}
    pages = []
    defined_pages = set(re.findall(r'^screen\.([A-Z_]+)\s*=', properties, re.M))
    sliders = re.search(r'^sliders\s*=\s*(.*)$', properties, re.M)[1].split()
    exposed = set()
    for page, tokens in re.findall(r'^screen\.([A-Z_]+)\s*=\s*(.*)$', properties, re.M):
        options = []
        for token in tokens.split():
            if token.startswith('['):
                if token[1:-1] not in defined_pages:
                    raise ValueError(f'Unknown subpage: {token}')
                continue
            match = re.search(r'^#define ' + re.escape(token) + r'\s+(\S+)\s*//\s*\[([^\]]+)\]',
                              settings, re.M) \
                or re.search(r'^const\s+\w+\s+' + re.escape(token) + r'\s*=\s*([^;\s]+);\s*//\s*\[([^\]]+)\]',
                             settings, re.M)
            if match is None:
                raise ValueError(f'Missing declared values for {token}')
            default, values = match[1], match[2].split()
            if Decimal(default) not in {Decimal(value) for value in values}:
                raise ValueError(f'Default outside allowed values: {token}={default}')
            if token not in DESCRIPTIONS:
                raise ValueError(f'Missing option description: {token}')
            for code, localized in labels.items():
                if 'option.' + token not in localized:
                    raise ValueError(f'Missing {code} option label: {token}')
            options.append({
                'id': token, 'default': default, 'values': values,
                'label': {code: localized['option.' + token] for code, localized in labels.items()},
                'description': DESCRIPTIONS[token], 'requires_mod': token in MOD_OPTIONS,
                'slider': token in sliders,
            })
            exposed.add(token)
        for code, localized in labels.items():
            if 'screen.' + page not in localized:
                raise ValueError(f'Missing {code} page label: {page}')
        pages.append({'id': page, 'label': labels['zh_CN']['screen.' + page], 'options': options})
    if not set(sliders).issubset(exposed):
        raise ValueError('Slider list contains unexposed settings')
    return {'version': (ROOT / 'VERSION').read_text().strip(), 'pages': pages,
            'profiles': profiles(properties, pages, labels)}


def profiles(properties, pages, labels):
    """Each preset must assign the same exposed options to allowed values."""
    allowed = {option['id']: {Decimal(value) for value in option['values']}
               for page in pages for option in page['options']}
    result = []
    keys = None
    for name in PROFILES:
        match = re.search(r'^profile\.' + name + r'\s*=\s*(.*)$', properties, re.M)
        if match is None:
            raise ValueError(f'Missing profile: {name}')
        values = dict(item.split('=', 1) for item in match[1].split())
        for option, value in values.items():
            if option not in allowed or Decimal(value) not in allowed[option]:
                raise ValueError(f'Invalid profile value: {name} {option}={value}')
        if keys is not None and set(values) != keys:
            raise ValueError(f'Profile {name} does not set the same options')
        keys = set(values)
        for code, localized in labels.items():
            if 'profile.' + name not in localized:
                raise ValueError(f'Missing {code} profile label: {name}')
        result.append({'id': name, 'label': labels['zh_CN']['profile.' + name], 'values': values})
    return result


def documents(data):
    """Render the full parameter table into the maintained prose template."""
    sections = []
    for page in data['pages']:
        sections.extend([
            '## ' + page['label'], '',
            '| 参数 | 标识 | 默认值 | 可选值 | 作用 |',
            '| --- | --- | --- | --- | --- |',
        ])
        for option in page['options']:
            note = option['description'] + (' 需要配套 Mod。' if option['requires_mod'] else '')
            sections.append('| ' + option['label']['zh_CN'] + ' | `' + option['id'] + '` | `'
                            + option['default'] + '` | ' + ', '.join(option['values']) + ' | ' + note + ' |')
        sections.append('')
    options = list(data['profiles'][0]['values'])
    sections.extend([
        '## 画质预设', '',
        '主页面的“预设”按钮一次切换下列选项；单独修改任一选项后显示为自定义。', '',
        '| 标识 | ' + ' | '.join(profile['label'] for profile in data['profiles']) + ' |',
        '| --- |' + ' --- |' * len(data['profiles']),
    ])
    for option in options:
        sections.append('| `' + option + '` | '
                        + ' | '.join(profile['values'][option] for profile in data['profiles']) + ' |')
    sections.append('')
    template = (ROOT / 'docs/configuration.template.md').read_text()
    if template.count('{{OPTIONS}}') != 1:
        raise ValueError('Configuration template must contain one options marker')
    return {
        ROOT / 'docs/configuration.md': template.replace('{{OPTIONS}}', '\n'.join(sections)),
        ROOT / 'docs/configuration.json': json.dumps(data, ensure_ascii=False, indent=2) + '\n',
    }


def main():
    """Generate documents or fail when committed documentation differs from source."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    arguments = parser.parse_args()
    data = configuration()
    for path, content in documents(data).items():
        if arguments.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f'Configuration document is stale: {path.name}')
        else:
            path.write_text(content)
    count = sum(len(page['options']) for page in data['pages'])
    print(f'Validated {count} settings in {len(data["pages"])} pages')


if __name__ == '__main__':
    main()
