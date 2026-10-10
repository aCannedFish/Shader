#!/usr/bin/env python3
"""Generate and validate the complete configuration reference from shader settings."""

import argparse
from decimal import Decimal
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DESCRIPTIONS = {
    'ENABLE_SHADOWS': '日月阴影总开关；0 关闭采样，1 开启。',
    'SHADOW_SOFTNESS': 'PCF 半径：0 单点，1 为 3×3，2 为 5×5；增大更柔和且采样更多。',
    'SHADOW_MAP_BIAS': '日月阴影纹素向近景集中的畸变强度；不要设置为 1。',
    'SHADOW_BIAS': '深度比较偏移；增大可缓解条纹，过大可能造成阴影脱离物体。',
    'AMBIENT_STRENGTH': '天空、暗部基础光与最低环境项倍率，局部点光单独控制。',
    'SUNLIGHT_STRENGTH': '太阳直射强度。',
    'MOONLIGHT_STRENGTH': '月光直射强度，独立于太阳并受月相影响。',
    'NIGHT_AMBIENT_STRENGTH': '夜间最低环境光，按当地天光减弱；不直接照亮封闭洞穴。',
    'NIGHT_EXPOSURE': '夜间最终场景曝光倍率。',
    'SKY_TINT': '环境光采用天空颜色的混合比例。',
    'BLOCK_LIGHT_STRENGTH': '火把等局部光强度；同时影响 Mod 求解，应等待重新收敛。',
    'BLOCK_LIGHT_FALLOFF': '原版局部光回退的衰减曲线，较大值使光源外围更暗。',
    'SMOOTH_BLOCK_LIGHT': '平滑原版传播光照采样，不模糊材质纹理。',
    'FOG_DENSITY': '加载距离雾浓度，并参与水下光程衰减倍率。',
    'UNDERWATER_MIN_VISIBILITY': '保留附近物体的最低环境与透射；远景继续衰减。',
    'UNDERWATER_SURFACE_SOFTNESS': '水下临界角过渡的宽度，增大可软化 Snell 窗口边界。',
    'UNDERWATER_DENSITY': '水下按光程的吸收和散射倍率。',
    'UNDERWATER_DEPTH_DIMMING': '随相机浸入深度减弱天空散射的倍率。',
    'WATER_SURFACE_OPACITY': '薄层散射不透明度；增大会减少水底细节。',
    'WATER_TURBIDITY': '水体浑浊度，作用于水面透射和水下光程衰减。',
    'WATER_ABSORPTION': '波长相关吸收强度，水内光程较长时颜色变化更明显。',
    'WATER_REFRACTION_STRENGTH': '水面与水下折射强度，0 不偏折，1 使用完整折射率变化。',
    'ENABLE_WATER_TEXTURE': '0 去掉水面贴图纹理，1 保留原版纹理；波浪另行控制。',
    'ENABLE_WATER_WAVES': '波浪位移和法线扰动开关。',
    'WATER_COLOR_LIGHTNESS': '水材质浅色混合比例，同时调整吸收颜色。',
    'WATER_ROUGHNESS': '日月高光宽度和水上倒影粗糙度；水下仍保持清晰采样。',
    'WATER_REFLECTION_STRENGTH': '水上 Fresnel 倒影和日月高光的整体倍率。',
    'WATER_SPECULAR_STRENGTH': '日月直接镜面高光的额外倍率。',
    'WATER_REFLECTION_BRIGHTNESS': '水上反射图像的亮度倍率，不改变倒影中的物体色相。',
    'ENABLE_FOLIAGE_WIND': '植被位移总开关，同时作用于日月阴影。',
    'WIND_STRENGTH': '植被风摆总幅度倍率。',
    'WIND_SPEED': '植被风摆时间速度倍率。',
    'LEAF_SWAY_STRENGTH': '树叶基础位移幅度，单位为方块。',
    'PLANT_SWAY_STRENGTH': '草木与庄稼基础位移幅度，根部权重为零。',
    'TONEMAP_MODE': '0 截断输出，1 ACES 近似，2 Reinhard。',
    'EXPOSURE': '日常 HDR 曝光倍率，夜间再乘夜间曝光。',
    'SATURATION': '最终饱和度，1 保持原值。',
    'CONTRAST': '最终对比度，1 保持原值。',
    'VIGNETTE': '屏幕边缘暗角强度，0 关闭。',
    'ENABLE_BLOOM': '泛光亮部提取开关。',
    'BLOOM_THRESHOLD': '泛光的 HDR 亮度阈值，较高值只保留更亮的区域。',
    'BLOOM_STRENGTH': '泛光叠加到最终画面的倍率。',
    'BLOOM_RADIUS': '5×5 泛光核的半径倍率。',
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
    'GI_VOLUME_SIZE': '辐射体积边长，单位为方块；体素成本随立方增长。',
    'GI_PROPAGATION_STEPS': '每次反弹的传播步数。',
    'GI_WORK_PER_FRAME': '每次渲染线程更新允许的 GI 工作量，增大可加快收敛。',
    'GI_STRENGTH': '表面接收已完成间接光场的强度倍率。',
    'GI_REFLECTANCE': '材质反照率之外的反弹能量保留比例，较大值可增加溢色。',
}
MOD_OPTIONS = {
    'ENABLE_COMPANION_LIGHTING', 'ENABLE_LOCAL_SHADOWS', 'LOCAL_LIGHT_COUNT',
    'LOCAL_LIGHT_RADIUS', 'LOCAL_SHADOW_RESOLUTION', 'LOCAL_SHADOW_UPDATES',
    'LOCAL_SHADOW_SOFTNESS', 'LOCAL_SHADOW_STRENGTH', 'LIGHTING_UPDATE_INTERVAL',
    'GI_BOUNCES', 'GI_VOLUME_SIZE', 'GI_PROPAGATION_STEPS', 'GI_WORK_PER_FRAME',
    'GI_STRENGTH', 'GI_REFLECTANCE',
}


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
    return {'version': (ROOT / 'VERSION').read_text().strip(), 'pages': pages}


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
