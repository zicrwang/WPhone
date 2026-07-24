# Incoming Call Sound

`WPhoneIncomingCall.wav` is copied into both the main app and Packet Tunnel
extension bundles. It is the fallback for both AlarmKit and the time-sensitive
incoming-call notification, while each path can have a separate runtime choice.

To replace it, keep the filename unchanged and provide a supported local
notification sound no longer than 10 seconds. The bundled file is a ten-second
mono, 22.05 kHz Linear PCM WAV. A supported WAV, CAF, or AIFF file can also be
selected independently for AlarmKit and the banner from the app. Runtime
selections are stored under distinct names in the App Group sounds directory
and do not modify this bundled fallback.
