"""Verify native RGB light data, depth-dependent absorption and displayed illumination."""

import json

from PIL import Image, ImageChops, ImageStat


def verify_colour_range(root):
    """Check distant hue, live updates and actual sky visibility through glass."""
    directory = root / '.preview/colour-range-review'
    cases = directory / 'cases'
    before = directory / 'before'
    result = {}
    for name in ('far', 'middle', 'near'):
        probe = json.loads((cases / f'colour_range_{name}-lighting.json').read_text())
        origin = probe['scene_origin']
        sources = [source for source in probe['colour_sources']
                   if abs(source[0] + origin[0] - 320.5) < 0.1
                   and abs(source[2] + origin[2] - 34.5) < 0.1]
        if len(sources) != 1 or not sources[0][6] > sources[0][4] * 5.0:
            raise RuntimeError('The visible soul torch lost its wide-field hue: ' + name)
        outside = any(coordinate < 0.0 or coordinate > 32.0 for coordinate in sources[0][:3])
        if name != 'near' and not outside:
            raise RuntimeError('The distant fixture accidentally depends on the near GI cube')
        result[name + '_source_outside_gi'] = outside

    wall = (935, 472, 995, 502)
    old = ImageStat.Stat(Image.open(before / 'colour_range_far.png').convert('RGB').crop(wall)).mean
    new = ImageStat.Stat(Image.open(cases / 'colour_range_far.png').convert('RGB').crop(wall)).mean
    if new[2] - new[0] < old[2] - old[0] + 15.0:
        raise RuntimeError('The remote receiver still displays default warm illumination')
    result['far_receiver_before_rgb'] = old
    result['far_receiver_after_rgb'] = new

    sky = (760, 400, 1160, 620)
    old = ImageStat.Stat(Image.open(before / 'colour_roof_red.png').convert('RGB').crop(sky)).mean
    new = ImageStat.Stat(Image.open(cases / 'colour_roof_red.png').convert('RGB').crop(sky)).mean
    if sum(new) / 3.0 < sum(old) / 3.0 + 50.0:
        raise RuntimeError('Red glass still blends over the empty black sky')
    for name in ('clear', 'red', 'blue'):
        patch = Image.open(cases / f'colour_roof_{name}.png').convert('RGB').crop((820, 240, 1100, 500))
        sun_pixels = sum(min(pixel) > 230 for pixel in patch.getdata())
        if sun_pixels < 1000:
            raise RuntimeError('The sun is hidden by the glass roof: ' + name)
        result[name + '_visible_sun_pixels'] = sun_pixels

    room = Image.open(cases / 'colour_room_photo.png').convert('RGB').crop((875, 440, 1045, 625))
    if sum(ImageStat.Stat(room).mean) / 3.0 < 140.0:
        raise RuntimeError('The original village test room still has an opaque dark skylight')
    result['original_room_sky_visible'] = True
    sun = json.loads((cases / 'colour_sun_red-lighting.json').read_text())['behind_transmission']
    if sun[0] < max(sun[1:]) * 3.0:
        raise RuntimeError('Fixing glass appearance disabled coloured sunlight transmission')
    result['coloured_sunlight_preserved'] = True
    latency = json.loads((cases / 'colour_update_latency.json').read_text())['client_to_gpu_ms']
    if not 0.0 <= latency < 500.0:
        raise RuntimeError('Known emitters still wait for the wide scan or GI: ' + str(latency))
    result['client_to_gpu_ms'] = latency
    result['poll_interval_ms'] = 100
    result['same_probe_observation'] = latency == 0.0
    (directory / 'verification.json').write_text(json.dumps(result, indent=2))
    return result


def verify_colour(root):
    """Use real framebuffer probes; tinted glass appearance alone cannot pass this check."""
    directory = root / '.preview/game/screenshots'
    names = ('torch', 'soul', 'redstone', 'sea', 'dark', 'glass_clear', 'glass_red',
             'glass_blue', 'glass_stack', 'glass_mixed', 'glass_pane', 'glass_opaque',
             'sun_clear', 'sun_red', 'sun_blue')
    probes = {}
    for name in names:
        path = directory / ('colour_' + name + '-lighting.json')
        if not path.exists():
            raise RuntimeError('Capture the colour source, glass and sun fixtures first: ' + name)
        probes[name] = json.loads(path.read_text())

    emitters = {}
    for name in ('torch', 'soul', 'redstone', 'sea'):
        probe = probes[name]
        if probe['light_count'] != 1:
            raise RuntimeError('The isolated source room contains extra emitters: ' + name)
        emitters[name] = probe['emitter_radiance'][0]
    r, g, b = emitters['torch']
    if not (r > g > b and b / r > 0.25):
        raise RuntimeError('The torch does not emit pale warm light')
    r, g, b = emitters['soul']
    if not (b > g * 1.5 and g > r * 2.0):
        raise RuntimeError('The soul torch is not blue')
    r, g, b = emitters['redstone']
    if not (r > g * 10.0 and r > b * 10.0):
        raise RuntimeError('The redstone torch is not red')
    if max(emitters['sea']) - min(emitters['sea']) > 0.005:
        raise RuntimeError('Sea-lantern illumination is not neutral white')

    transmission = {name: probes[name]['behind_transmission'] for name in names}
    for name in names:
        if max(abs(v - 1.0) for v in probes[name]['front_transmission']) > 0.002:
            raise RuntimeError('A filter tints light-facing geometry: ' + name)
        if any(not 0.0 <= v <= 1.001 for v in transmission[name]):
            raise RuntimeError('Passive glass increases energy or has invalid transmission: ' + name)
    for name in ('glass_red', 'sun_red'):
        r, g, b = transmission[name]
        if r < max(g, b) * 3.0:
            raise RuntimeError('Red glass does not selectively absorb green/blue: ' + name)
    for name in ('glass_blue', 'sun_blue'):
        r, g, b = transmission[name]
        if b < max(r, g) * 2.0:
            raise RuntimeError('Blue glass does not selectively transmit blue: ' + name)
    red, blue = transmission['glass_red'], transmission['glass_blue']
    for index in range(3):
        if abs(transmission['glass_stack'][index] - red[index] ** 2) > 0.02:
            raise RuntimeError('Two layers do not multiply transmission')
        if abs(transmission['glass_mixed'][index] - red[index] * blue[index]) > 0.02:
            raise RuntimeError('Mixed glass layers replace rather than multiply colour')
        if abs(transmission['glass_pane'][index] - red[index]) > 0.02:
            raise RuntimeError('The thin pane is missed or treated as a solid cube')

    def image(name):
        return Image.open(directory / ('colour_' + name + '.png')).convert('RGB')

    dark = image('dark')
    floor = (700, 650, 1220, 940)
    displayed = {}
    for name in ('torch', 'soul', 'redstone', 'sea'):
        gain = ImageChops.subtract(image(name), dark).crop(floor)
        displayed[name] = ImageStat.Stat(gain).mean
        if max(displayed[name]) < 0.15:
            raise RuntimeError('Source colour is absent from the displayed floor: ' + name)
    if displayed['soul'][2] <= displayed['soul'][0] * 1.3:
        raise RuntimeError('Displayed soul illumination is not blue')
    if displayed['redstone'][0] <= displayed['redstone'][2] * 1.3:
        raise RuntimeError('Displayed redstone illumination is not red')

    sun = {name: ImageStat.Stat(image(name).crop((500, 520, 1420, 880))).mean
           for name in ('sun_clear', 'sun_red', 'sun_blue')}
    if sun['sun_red'][0] <= sun['sun_red'][1] * 1.1:
        raise RuntimeError('Red sunlight is not visible on the receiver')
    if sun['sun_blue'][2] <= sun['sun_blue'][0] * 1.1:
        raise RuntimeError('Blue sunlight is not visible on the receiver')

    result = {'emitter_radiance': emitters, 'transmission': transmission,
              'displayed_floor_gain': displayed, 'displayed_sunlight': sun}
    output = root / '.preview/coloured-verification'
    output.mkdir(exist_ok=True)
    (output / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)
    return result


def verify_colour_origin(root):
    """Check the actual shader coordinate frame, including translated geometry and grass."""
    directory = root / '.preview/game/screenshots'
    names = ('origin', 'positive', 'negative', 'z', 'sun')
    frames = {}
    for name in names + ('user_grass', 'user_quartz'):
        scene = 'colour_' + name if name.startswith('user_') else 'colour_wrap_' + name
        path = directory / (scene + '-lighting.json')
        if not path.exists():
            raise RuntimeError('Capture coordinate-frame fixtures first: ' + scene)
        data = json.loads(path.read_text())
        camera = data['cameraPosition']
        absolute = data['world_camera']
        offset = [a - b for a, b in zip(absolute, camera)]
        expected = [a - b for a, b in zip(data['scene_origin'], offset)]
        for uniform in ('companionOrigin', 'companionGiOrigin'):
            error = max(abs(a - b) for a, b in zip(data[uniform], expected))
            if error > 0.01:
                raise RuntimeError(f'{scene}: {uniform} is in a different coordinate frame: {error}')
        local_camera = [a - b for a, b in zip(camera, data['companionOrigin'])]
        if not all(6.0 <= value <= 26.0 for value in local_camera):
            raise RuntimeError('The camera is falsely outside the local lighting volume: ' + scene)
        frames[scene] = {'offset': offset, 'camera_in_volume': local_camera}
    for name in ('positive', 'negative', 'z', 'sun'):
        if max(abs(v) for v in frames['colour_wrap_' + name]['offset']) < 999.0:
            raise RuntimeError('The fixture did not exercise camera rebasing: ' + name)

    def image(name):
        return Image.open(directory / (name + '.png')).convert('RGB')

    reference = image('colour_wrap_origin')
    differences = {}
    for name in ('positive', 'negative', 'z'):
        delta = ImageChops.difference(reference, image('colour_wrap_' + name)).crop((350, 250, 1570, 1000))
        differences[name] = sum(ImageStat.Stat(delta).mean) / 3.0
        if differences[name] > 1.0:
            raise RuntimeError('Moving an identical room changes the displayed lighting: ' + name)
    sunlight = ImageStat.Stat(image('colour_wrap_sun').crop((500, 520, 1420, 880))).mean
    if sunlight[0] < sunlight[1] * 1.1:
        raise RuntimeError('Coloured solar transmission fails after camera rebasing')
    output = root / '.preview/coloured-origin-verification'
    output.mkdir(exist_ok=True)
    result = {'coordinate_frames': frames, 'translated_room_mean_error': differences,
              'far_sunlight': sunlight}
    (output / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)
    return result
