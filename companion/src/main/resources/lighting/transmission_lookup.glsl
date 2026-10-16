/* RGB caches share the point-shadow atlas; metadata describes their padded slices. */
vec3 cachedTransmission(int index, vec3 position) {
    vec4 cacheData = texelFetch(uShadowAtlas, ivec2(2, 0), 0);
    if (cacheData.w < 0.5) {
        return vec3(1.0);
    }
    float side = float(uSize + 2);
    float rows = ceil(float(uSize) / 8.0);
    float columns = cacheData.z;
    vec2 corner = vec2(mod(float(index), columns) * side * 8.0,
        cacheData.y + floor(float(index) / columns) * side * rows);
    vec3 p = clamp(position - 0.5, vec3(0.0), vec3(uSize - 1));
    float first = floor(p.z);
    float second = min(first + 1.0, float(uSize - 1));
    vec2 a = corner + vec2(mod(first, 8.0), floor(first / 8.0)) * side;
    vec2 b = corner + vec2(mod(second, 8.0), floor(second / 8.0)) * side;
    vec3 lower = texture(uShadowAtlas, (a + p.xy + 1.5) / vec2(uAtlasSize)).rgb;
    vec3 upper = texture(uShadowAtlas, (b + p.xy + 1.5) / vec2(uAtlasSize)).rgb;
    return clamp(mix(lower, upper, fract(p.z)), vec3(0.0), vec3(1.0));
}
