# Incoming Call Sound

`WPhoneIncomingCall.wav` is copied into both the main app and Packet Tunnel
extension bundles. AlarmKit and the time-sensitive incoming-call notification
use that same file.

To replace it, keep the filename unchanged and provide a supported local
notification sound no longer than 30 seconds. A five-second Linear PCM WAV is
recommended for this project.
