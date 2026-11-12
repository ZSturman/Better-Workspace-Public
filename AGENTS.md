# Better Workspace public source

This is a clean release snapshot. `project.yml` is authoritative; run `xcodegen generate` rather than editing the generated project. Read README.md and docs/GETTING_STARTED.md first.

- Keep normal folder browsing read-only. Explicit reviewed capture filing, work edits, recoverable item deletion and previewed creation of checked missing starter directories are bounded exceptions.
- Never inspect other tools' metadata. Preserve user data, private iCloud records and unrelated Notion content.
- Use native SwiftUI/AppKit/UIKit; UI state belongs on the main actor. Do not reintroduce SwiftUI `.inspector` or toolbar `.searchable`.
- Use disposable fixtures. Do not run personal-workspace diagnostics, install a service over an existing personal service, or replace a personal app for testing.
- Run targeted checks first. Mac: `xcodebuild -project BetterWorkspace.xcodeproj -scheme BetterWorkspace -destination 'platform=macOS,arch=arm64' test -only-testing:BetterWorkspaceCoreTests/YourTestClass`.
- Test deployments and signing with your own developer team and capabilities. Never commit credentials or runtime data.

Development milestones are distinct from release acceptance. Preserve verified core
behavior and continue independent work around noncritical/blocked acceptance checks.
Do not claim deferred filesystem structural actions or distribution acceptance passed.
