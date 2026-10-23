#ifndef SIMPLE_WORLD_CHOICE_PACKING_GLSL
#define SIMPLE_WORLD_CHOICE_PACKING_GLSL

struct WorldChoiceGroup {
    int count;
    int channel;
    int shift;
    int sumBits;
    int squareBits;
    int countBits;
    int maximumSamples;
    int radix;
    int choiceBit;
    int coverageShift;
    int coverageBits;
    int maximumCoverage;
    int fallback;
    bool constraints;
};

WorldChoiceGroup worldChoiceGroup(ivec4 first, ivec4 second, ivec4 third) {
    return WorldChoiceGroup(first.x, first.y % 4, first.z, first.w,
        second.x, second.y, second.z, second.w, (first.y % 1024) / 4,
        third.x, third.y, third.z, third.w - 1, first.y >= 1024);
}

uint worldChoiceMask(int bits) {
    return (1u << uint(bits)) - 1u;
}

vec4 worldChoiceContribution(WorldChoiceGroup group, int choice) {
    uint code = uint(choice + 1);
    uint payload = code | ((code * code) << uint(group.sumBits))
        | (1u << uint(group.sumBits + group.squareBits));
    uvec4 words = uvec4(0u);
    words[group.channel] = payload << uint(group.shift);
    return vec4(words);
}

// Ambiguous individual faces vote against incompatible candidates. Several
// faces can identify a rotation even when none is a unique witness by itself.
vec4 worldChoiceConstraintContribution(WorldChoiceGroup group, uint compatible) {
    uvec4 words = uvec4(0u);
    for (int choice = 0; choice < 16; choice++) {
        if (choice >= group.count) break;
        if ((compatible & (1u << uint(group.choiceBit + choice))) != 0u) continue;
        int bit = choice * group.sumBits;
        words[group.channel + bit / 24] |= 1u << uint(bit % 24);
    }
    words.w = 1u << uint(group.coverageShift);
    return vec4(words);
}

vec4 worldChoiceCoverage(WorldChoiceGroup group) {
    if (group.coverageBits == 0) return vec4(0.0);
    return vec4(0.0, 0.0, 0.0, float(1u << uint(group.coverageShift)));
}

// Sum and squared sum must have zero variance. Averaging conflicting source
// choices cannot accidentally turn into a third, apparently valid model.
int worldDecodeChoice(vec4 accumulation, WorldChoiceGroup group) {
    if (any(isnan(accumulation)) || any(isinf(accumulation))
        || any(lessThan(accumulation, vec4(0.0)))
        || any(greaterThan(accumulation, vec4(16777215.0)))
        || any(notEqual(accumulation, floor(accumulation)))) return -1;
    if (group.constraints) {
        uint coverage = (uint(accumulation.w) >> uint(group.coverageShift)) & worldChoiceMask(group.coverageBits);
        if (coverage == 0u || coverage > uint(group.maximumSamples)) return -1;
        int selected = -1;
        for (int choice = 0; choice < 16; choice++) {
            if (choice >= group.count) break;
            int bit = choice * group.sumBits;
            uint votes = (uint(accumulation[group.channel + bit / 24]) >> uint(bit % 24))
                & worldChoiceMask(group.sumBits);
            if (votes > coverage) return -1;
            if (votes == 0u) {
                if (selected >= 0) return -1;
                selected = choice;
            }
        }
        return selected;
    }
    uint word = uint(accumulation[group.channel]) >> uint(group.shift);
    uint guard = (word >> uint(group.sumBits + group.squareBits + group.countBits)) & 1u;
    if (guard != 0u) return -1;
    uint sum = word & worldChoiceMask(group.sumBits);
    uint squares = (word >> uint(group.sumBits)) & worldChoiceMask(group.squareBits);
    uint count = (word >> uint(group.sumBits + group.squareBits)) & worldChoiceMask(group.countBits);
    if (count > 0u) {
        if (count > uint(group.maximumSamples) || sum < count || sum > count * uint(group.count)
            || sum * sum != count * squares || sum % count != 0u) return -1;
        return int(sum / count) - 1;
    }
    if (sum != 0u || squares != 0u || group.fallback < 0 || group.coverageBits == 0) return -1;
    uint coverage = (uint(accumulation.w) >> uint(group.coverageShift)) & worldChoiceMask(group.coverageBits);
    if (coverage == 0u || coverage > uint(group.maximumCoverage)) return -1;
    return group.fallback;
}
#endif
