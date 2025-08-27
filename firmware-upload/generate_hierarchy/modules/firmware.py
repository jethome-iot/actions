import sys

def generate(subtypes, load_json):
    # subtypes: [fwtype, <device>, channel]
    # subtype fwtype: release, bootloader, coordinator, _router_, espjhome
    # subtype device: jxd-r6, jxd-r6-lcd, etc (can be ommited)
    # subtype channel: release, rc, nightly, branch-name
    if len(subtypes) < 2:
        print("Error: For Firmware, need channel, fwtype")
        sys.exit(2)
    if len(subtypes) == 3:
        fwtype, device, channel = subtypes[:3]
    else:
        fwtype, channel = subtypes[:2]
        device = None
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
    fwtypechannel['final'] = True
    if device:
        fwtypedevice = {}
        fwtypedevice['slug'] = device.lower()
        fwtypedevice['name'] = device
        fwtypedevice['final'] = False
        fwtypedevice['is_active'] = True
        fwtypedevice['subtypes'] = [fwtypechannel]
        fwtype['subtypes'] = [fwtypedevice]
    else:
        fwtype['subtypes'] = [fwtypechannel]
    return fwtype
