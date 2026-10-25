/* Reconstruct the reduced underwater shaft field using optical path depth.
 * The first texel is frame metadata and never contributes shaft radiance. */
#ifndef LIB_WATER_SHAFTS_FILTER_GLSL
#define LIB_WATER_SHAFTS_FILTER_GLSL
float estimateUnderwaterDepth() {
#ifdef WORLD_BASE_OPTICS
    return vUnderwaterDepth;
#else
    return texture2D(colortex4, vec2(0.5) / vec2(viewWidth, viewHeight)).a;
#endif
}

// alpha 保存积分终点，拒绝跨越近处遮挡物的散射，首个元数据纹素不参与重建。
vec3 sampleWaterShafts(vec2 uv, float pathLength) {
    if (UNDERWATER_SHAFT_STRENGTH <= 0.0) {
        return vec3(0.0);
    }
    vec2 size = volumeSize();
    vec2 pixel = uv * size - 0.5;
    vec2 base = floor(pixel);
    vec2 fraction = fract(pixel);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float distance = min(pathLength, 48.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            vec2 cell = clamp(base + vec2(float(x), float(y)), vec2(0.0), size - 1.0);
            if (cell.x < 0.5 && cell.y < 0.5) {
                continue;
            }
            vec4 fieldSample = texture2D(colortex4, (cell + 0.5) / vec2(viewWidth, viewHeight));
            float spatial = (x == 0 ? 1.0 - fraction.x : fraction.x)
                          * (y == 0 ? 1.0 - fraction.y : fraction.y);
            float weight = spatial * exp(-abs(fieldSample.a - distance) / max(distance * 0.08, 0.15));
            sum += fieldSample.rgb * weight;
            total += weight;
        }
    }
    return total > EPSILON ? sum / total : vec3(0.0);
}

#endif
