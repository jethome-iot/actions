#!/usr/bin/python
import json
import sys
import os

__location__ = os.path.realpath(
    os.path.join(os.getcwd(), os.path.dirname(__file__)))

TEMPLATE_PATH = os.path.join(__location__, 'templates')

def print_help(name):
    # Use a breakpoint in the code line below to debug your script.
    print(''' generate_hierarchy Gerenate json for firmware storage
    python generate_hierarchy brand platform os channel ...
        brand - JetHome
        platform - jethub-j100, jethub-j80
        os - Armbian, JHAOS etc
        ''''generate_hierarchy help:\n\tpython generate_hierachy arg')  # Press Ctrl+F8 to toggle the breakpoint.


def generate_armbian():
    release = sys.argv[5]
    branch = sys.argv[6]
    with open(os.path.join(TEMPLATE_PATH, 'armbian/releases.json')) as json_file:
        releases = json.load(json_file)

    with open(os.path.join(TEMPLATE_PATH, 'armbian/branches.json')) as json_file:
        branches = json.load(json_file)

    # print (i, platform)
    # fw types tree
    fwtyperelease = releases[release]  # focal,jammy,bulseye
    fwtypebranches = branches[branch]  # current, edge

    fwtyperelease['subtypes'] = [fwtypebranches]
    #fwtypechannel['subtypes'] = [fwtyperelease]
    return fwtyperelease


def generate_jhaos():
    pass

def generate_armbianha():
    pass


def generate_burntools():
    pass

def generate_firmware():
    fwtype = sys.argv[5]
    with open(os.path.join(TEMPLATE_PATH, 'firmware/type.json')) as json_file:
        fwtypes = json.load(json_file)

    # print (i, platform)
    # fw types tree
    fwtyperelease = fwtypes[fwtype]  # focal,jammy,bulseye

    return fwtyperelease


# Press the green button in the gutter to run the script.
if __name__ == '__main__':
    '''
    fwjson.py platform os channel release branch version
    '''
    if len(sys.argv) - 1 > 3:
        '''
        Read first 4 args (common for all):
        brand - JetHome
        platform - j100, j80, z2
        project - Armbian, JHAOS, Firmware etc
        channel - release, rc, nightly, branch-name
        '''
        brandA = sys.argv[1]
        platform = sys.argv[2]
        projectos = sys.argv[3]
        channel = sys.argv[4]
    else:
        print_help(sys.argv[0])
        exit(-1)

    with open(os.path.join(TEMPLATE_PATH, 'projects.json')) as json_file:
        projects = json.load(json_file)
    with open(os.path.join(TEMPLATE_PATH, 'brand.json')) as json_file:
        brands = json.load(json_file)
    with open(os.path.join(TEMPLATE_PATH, 'platforms.json')) as json_file:
        platforms = json.load(json_file)
    with open(os.path.join(TEMPLATE_PATH, 'channels.json')) as json_file:
        channels = json.load(json_file)

    if brandA in brands.keys():
        brand = brands[brandA]  # jethome etc
    else:
        print("Error: Brand not found")
        print_help(sys.argv[0])
        exit(255)

    if projectos in projects.keys():
        '''
        Select "project"
        '''
        func = getattr(sys.modules[__name__], 'generate_' + projects[projectos]['slug'].lower())
        fwtyperelease = func()

        fwtype = projects[projectos]
        plat = platforms[platform]

        if channel in channels.keys():
            fwtypechannel = channels[channel]  # release,rc,nightly
        else:
            fwtypechannel = channels['nightly']  # release,rc,nightly
            fwtypechannel['name'] = 'Nightly branch: ' + channel
            fwtypechannel['slug'] = channel.lower()

        if fwtyperelease is not None:
            fwtypechannel['subtypes'] = [fwtyperelease]
        else:
            fwtypechannel.pop('subtypes', None)
            fwtypechannel['final'] = True

        fwtype['subtypes'] = [fwtypechannel]
        plat['firmware_types'] = [fwtype]
        brand["platforms"] = [plat]

        print(json.dumps([brand], sort_keys=True, indent=4))
    else:
        print("Error: Project not found\n")
        print_help(sys.argv[0])

