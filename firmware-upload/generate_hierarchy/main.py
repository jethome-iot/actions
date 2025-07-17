#!/usr/bin/python3
import importlib
import json
import sys
import os
import copy

__location__ = os.path.realpath(
    os.path.join(os.getcwd(), os.path.dirname(__file__))
)

TEMPLATE_PATH = os.path.join(__location__, 'templates')

MODULES_PATH = os.path.join(__location__, 'modules')

def load_generators():
    generators = {}
    for fname in os.listdir(MODULES_PATH):
        if fname.endswith('.py') and fname != '__init__.py':
            modname = fname[:-3]
            module = importlib.import_module(f'modules.{modname}')
            # Для каждого модуля требуем функцию generate(subtypes)
            if hasattr(module, 'generate'):
                generators[modname] = module.generate
                if hasattr(module, 'ALIAS'):
                    for alias in module.ALIAS:
                        generators[alias] = module.generate
    return generators

GENERATOR_DISPATCH = load_generators()


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
    fwtype_channel_tree = gen_func(subtypes, load_json)
    if fwtype_channel_tree:
        project['subtypes'] = [fwtype_channel_tree]
    plat['firmware_types'] = [project]
    brand['platforms'] = [plat]

    print(json.dumps([brand], sort_keys=True, indent=4))

if __name__ == '__main__':
    main()
