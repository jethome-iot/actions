import sys

def generate(subtypes, load_json):
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
    fwtypechannel.pop('subtypes', None)
    fwtypechannel['final'] = 'true'
    fwtype['subtypes'] = [fwtypechannel]
    return fwtype
