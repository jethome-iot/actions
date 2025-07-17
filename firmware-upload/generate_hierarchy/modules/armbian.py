import sys

def generate(subtypes, load_json):
    """
    Генератор для Armbian:
    subtypes: [channel, release, branch]
    load_json: функция-загрузчик JSON (должна быть передана из main.py)
    """
    if len(subtypes) < 3:
        print("Error: For Armbian, need at least channel, release, branch")
        sys.exit(2)

    if len(subtypes) == 4:
        channel, release, clitype, branch = subtypes[:4]
    else:
        channel, release, branch = subtypes[:3]
        clitype = None

    releases = load_json('armbian/releases.json')
    branches = load_json('armbian/branches.json')
    channels = load_json('channels.json')
    clitypes = load_json('armbian/clitypes.json') if clitype else None
    try:
        fwtyperelease = releases[release]
        fwtypebranch = branches[branch]
    except KeyError as e:
        print(f"Unknown release/branch: {e}")
        sys.exit(2)
    if clitype:
        try:
            fwtypecli = clitypes[clitype]
            fwtypecli['subtypes'] = [fwtypebranch]
            fwtyperelease['subtypes'] = [fwtypecli]

        except KeyError as e:
            print(f"Unknown clitype: {e}")
            sys.exit(2)
    else:
        fwtyperelease['subtypes'] = [fwtypebranch]
    # channel
    if channel in channels:
        fwtypechannel = channels[channel]
    else:
        fwtypechannel = channels['nightly']
        fwtypechannel['name'] = 'Nightly branch: ' + channel
        fwtypechannel['slug'] = channel.lower()
    fwtypechannel['subtypes'] = [fwtyperelease]
    return fwtypechannel
