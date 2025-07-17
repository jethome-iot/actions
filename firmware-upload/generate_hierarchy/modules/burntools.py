import sys

ALIAS = ['magicos', 'armbianha', 'jhaos', 'burntools']

# Generic firmware storage json generator

def generate(subtypes, load_json):
    # subtypes: [channel]
    # subtype channel: release, rc, nightly, branch-name
    if len(subtypes) != 0:
        print(f'Error: For {__name__} no need channel')
        sys.exit(2)
    return None
