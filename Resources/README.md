# Incoming Call Sound

`WPhoneIncomingCall.wav` is copied into both the main app and Packet Tunnel
extension bundles. It is the fallback for the time-sensitive incoming-call
notification.

To replace the bundled fallback, keep the filename unchanged and provide a
supported sound. The bundled file is a ten-second mono, 22.05 kHz Linear PCM
WAV. A supported WAV, CAF, or AIFF file can also be selected from the app, with
a maximum duration of 29 seconds. The runtime selection is stored in the App
Group sounds directory and does not modify this bundled fallback.

## Source notification icons

`NotificationIcons/Wechat.png`, `SMS.png`, `Phone.png`, and `Email.png` are
copied into the Packet Tunnel extension bundle. The extension chooses one only
from the first segment of a validated event `source`: `wechat`, `sms`, `phone`,
or `email`. They are notification-source avatars and do not change WPhone's
application icon. The images are not accepted from event payloads or URLs.
