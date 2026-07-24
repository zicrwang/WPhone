# Incoming Call Sound

`WPhoneIncomingCall.wav` is copied into both the main app and Packet Tunnel
extension bundles. It is the fallback for the time-sensitive incoming-call
notification.

To replace the bundled fallback, keep the filename unchanged and provide a
supported sound. The bundled file is a ten-second mono, 22.05 kHz Linear PCM
WAV. A supported WAV, CAF, or AIFF file can also be selected from the app, with
a maximum duration of 29 seconds. The runtime selection is stored in the App
Group sounds directory and does not modify this bundled fallback.
