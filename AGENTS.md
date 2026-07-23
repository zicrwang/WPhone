# WPhone Project Instructions

- Keep the main app bundle identifier fixed at `app.wephone.vpn`.
- Keep the packet tunnel extension bundle identifier fixed at `app.wephone.vpn.PacketTunnel`.
- Do not build, package, upload, or trigger creation of an IPA unless the user explicitly requests an IPA build in the current conversation.
- Routine source changes may be committed and pushed without running the GitHub Actions IPA workflow.
- The GitHub Actions IPA workflow must remain manually triggered with `workflow_dispatch`; do not add automatic `push`, `pull_request`, or scheduled triggers.
- The cloud build produces an unsigned IPA containing the embedded `PacketTunnel.appex`. Do not add certificate, provisioning profile, Apple signing, or signing-secret requirements unless the user explicitly changes this policy.
