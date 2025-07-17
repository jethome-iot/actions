import sys

def generate(subtypes, load_json):
    # subtypes: [fwtype, channel]
    # subtype fwtype: release, bootloader, coordinator, _router_, espjhome
    # subtype channel: release, rc, nightly, branch-name
    if len(subtypes) < 1:
        print(f'Error: For {__name__}, need channel')
        sys.exit(2)
    channel = subtypes[0]
    channels = load_json('channels.json')
    if channel in channels:
        fwtypechannel = channels[channel]
    else:
        fwtypechannel = channels['nightly']
        fwtypechannel['name'] = 'Nightly branch: ' + channel
        fwtypechannel['slug'] = channel.lower()
    fwtypechannel['final'] = True
    fwtypechannel.pop('subtypes', None)
    return fwtypechannel
