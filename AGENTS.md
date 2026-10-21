# ScrollStitch contributor rules

- Use the current branch by default. Do not create or switch development branches, detached checkouts, or worktrees without the user's explicit request or consent.
- Harness owns agent workflow state. Store only portable commands in `.harness/project.json`; keep runs, logs, generated evidence and worktrees ignored. Use a fresh review task for new work; do not reuse historical acceptance as current proof.
- Before Computer Use or GUI automation, describe purpose and scope and obtain explicit approval for that task. CLI builds, local file checks and API requests are separate. Do not launch Xcode, a simulator or phone automation indirectly through scripts without GUI approval.
- Preserve App identity, App Group, existing works and uncertain Photos write records. Device installation requires task-specific authorization; back up and verify existing device data before an authorized update. Explicit user requests to delete local backups override retention for those backups only.
- Developer edition requires iOS 27+ and ScreenCaptureKit. `ScrollStitchStore` is collage-only. Do not reintroduce ReplayKit or legacy capture entry points.
- Capture is single-session, processes images locally and retains no audio. Normal completion must reconstruct complete content and save automatically. Do not require frame selection, cropping or manual seam repair. Never automatically repeat an uncertain Photos write.
- Keep annual data updates atomic and verified. Alarm time is Asia/Shanghai; report system-confirmed coverage and missing years honestly. Do not claim indefinite offline replenishment.
- Update code, current documentation and meaningful tests together. Use README and docs/testing.md commands. Compilation, file replay, mocked scheduling, actual device ringing and Store publication are distinct evidence layers.
- Never publish local signing configuration, credentials, private recordings, works backups, device identifiers, logs, build caches or Harness state. Check the Git index as well as `.gitignore`.
