# Incoming Call Sound

`WPhoneIncomingCall.wav` is copied into both the main app and Packet Tunnel
extension bundles. AlarmKit and the time-sensitive incoming-call notification
use that same file.

To replace it, keep the filename unchanged and provide a supported local
notification sound no longer than 10 seconds. The bundled file is a ten-second
mono, 22.05 kHz Linear PCM WAV. A supported WAV, CAF, or AIFF file can also be
selected from the app; runtime selections are stored in the App Group sounds
directory and do not modify this bundled fallback.
