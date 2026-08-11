# Development environment

- The local development machine is Windows; the arcade cabinet is Linux/Bazzite.
- Do not run or simulate Linux/cabinet subsystem behavior on Windows. This includes system volume or mute, sleep/power management, systemd services, PipeWire/PulseAudio commands, controller-remapper integration, and real game-process lifecycle behavior.
- Do not run the launcher, Godot scenes, or any automated project tests on Windows, even if a test appears platform-neutral. Do not invoke the Godot editor or headless Godot for verification.
- Verify runtime behavior only on the arcade hardware. On Windows, use static inspection and non-executing checks such as reviewing diffs or searching source text, then report that runtime tests were not run because the environment is Windows.
