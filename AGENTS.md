# Development environment

- The local development machine is Windows; the arcade cabinet is Linux/Bazzite.
- Do not run or simulate Linux/cabinet subsystem behavior on Windows. This includes system volume or mute, sleep/power management, systemd services, PipeWire/PulseAudio commands, controller-remapper integration, and real game-process lifecycle behavior.
- Verify those behaviors only on the arcade hardware. On Windows, limit verification to static inspection and tests that are explicitly platform-neutral; do not run a broader suite when it includes cabinet-specific behavior.
- Avoid running the Godot editor solely to refresh test metadata or class caches. If a Windows-safe test cannot start because its Godot cache is stale, report that limitation instead of forcing an editor import.
