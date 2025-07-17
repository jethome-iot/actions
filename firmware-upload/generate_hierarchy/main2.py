#!/usr/bin/python3
import json
import sys
import os
import copy

__location__ = os.path.realpath(
    os.path.join(os.getcwd(), os.path.dirname(__file__))
)

TEMPLATE_PATH = os.path.join(__location__, 'templates')

def print_help(name):
    print(f'''generate_hierarchy — Generate JSON for firmware storage
Usage: python {name} brand platform project [subtype1 [subtype2 ...]]
    brand     - JetHome
    platform  - j100, j80, firmware, ...
    project   - Armbian, JHAOS, Firmware, ...
    (subtypes depend on project: channel, release, branch, ...)
Example:
    python {name} JetHome j100 Armbian release jammy current
    python {name} JetHome j100 Firmware nightly my_fwtype
''')

def load_json(filename):
    with open(os.path.join(TEMPLATE_PATH, filename)) as f:
        return json.load(f)

def generate_armbian(subtypes):
    # subtypes: [channel, release, branch]
    if len(subtypes) < 3:
        print("Error: For Armbian, need channel, release, branch")
        sys.exit(2)
    channel, release, branch = subtypes[:3]
    releases = load_json('armbian/releases.json')
    branches = load_json('armbian/branches.json')
    channels = load_json('channels.json')
    try:
        fwtyperelease = copy.deepcopy(releases[release])
        fwtypebranch = copy.deepcopy(branches[branch])
    except KeyError as e:
        print(f"Unknown release/branch: {e}")
        sys.exit(2)
    fwtyperelease['subtypes'] = [fwtypebranch]
    # channel
    if channel in channels:
        fwtypechannel = copy.deepcopy(channels[channel])
    else:
        fwtypechannel = copy.deepcopy(channels['nightly'])
        fwtypechannel['name'] = 'Nightly branch: ' + channel
        fwtypechannel['slug'] = channel.lower()
    fwtypechannel['subtypes'] = [fwtyperelease]
    return fwtypechannel

def generate_firmware(subtypes):
    # subtypes: [fwtype, channel]
    # subtype fwtype: release, bootloader, coordinator, _router_, espjhome
    # subtype channel: release, rc, nightly, branch-name
    if len(subtypes) < 2:
        print("Error: For Firmware, need channel, fwtype")
        sys.exit(2)
    fwtype, channel = subtypes[:2]
    fwtypes = load_json('firmware/type.json')
    channels = load_json('channels.json')
    try:
        fwtype = fwtypes[fwtype]
    except KeyError as e:
        print(f"Unknown fwtype: {e}")
        sys.exit(2)
    if channel in channels:
        fwtypechannel = channels[channel]
    else:
        fwtypechannel = channels['nightly']
        fwtypechannel['name'] = 'Nightly branch: ' + channel
        fwtypechannel['slug'] = channel.lower()
    fwtypechannel['final'] = 'true'
    fwtype['subtypes'] = [fwtypechannel]
    return fwtype

def generate_jhaos(subtypes):
    print("JHAOS not implemented.")
    sys.exit(3)

def generate_magicos(subtypes):
    print("Magicos not implemented.")
    pass
    sys.exit(3)

def generate_espjhome(subtypes):
    print("oops")
    if len(subtypes) < 1:
      print("Error: For ESPJHome, need at least one subtype")
      sys.exit(2)
    subtype = subtypes[0]
    espjhome_types = load_json('espjhome/types.json')
    try:
        fwtype = copy.deepcopy(espjhome_types[subtype])
    except KeyError as e:
        print(f"Unknown ESPJHome type: {e}")
        sys.exit(2)
    return fwtype

def generate_armbianha(subtypes):
    print("ArmbianHA not implemented.")
    sys.exit(3)

def generate_burntools(subtypes):
    print("Burntools not implemented.")
    sys.exit(3)

# Маппинг project slug → функция
GENERATOR_DISPATCH = {
    "armbian": generate_armbian,
    "armbianha": generate_armbianha,
    "jhaos": generate_jhaos,
    "magicos": generate_magicos,
    "firmware": generate_firmware,
    "burntools": generate_burntools,
    "espjhome": generate_espjhome,

}

def main():
    if len(sys.argv) < 4:
        print_help(sys.argv[0])
        sys.exit(1)
    # Последовательные аргументы
    brand_name = sys.argv[1]
    platform_name = sys.argv[2]
    projectos = sys.argv[3]
    subtypes = sys.argv[4:]  # всё, что дальше — как есть

    # Загрузка базовых json-структур
    brands = load_json('brand.json')
    platforms = load_json('platforms.json')
    projects = load_json('projects.json')

    if brand_name not in brands:
        print(f"Error: Brand '{brand_name}' not found.")
        sys.exit(255)
    if platform_name not in platforms:
        print(f"Error: Platform '{platform_name}' not found.")
        sys.exit(255)
    if projectos not in projects:
        print(f"Error: Project '{projectos}' not found.")
        sys.exit(255)

    brand = copy.deepcopy(brands[brand_name])
    plat = copy.deepcopy(platforms[platform_name])
    project = copy.deepcopy(projects[projectos])
    slug = project['slug'].lower()
    gen_func = GENERATOR_DISPATCH.get(slug)
    if not gen_func:
        print(f"No generator for project '{projectos}' (slug: {slug})")
        sys.exit(255)

    # Сборка дерева по генератору (канал → релиз → ветка …)
    fwtype_channel_tree = gen_func(subtypes)
    project['subtypes'] = [fwtype_channel_tree]
    plat['firmware_types'] = [project]
    brand['platforms'] = [plat]

    print(json.dumps([brand], sort_keys=True, indent=4))

if __name__ == '__main__':
    main()
