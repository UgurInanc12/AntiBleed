# Xcode Project

This placeholder exists so the repo layout is complete on Windows.

On the Mac, create the real project:

1. Xcode -> New Project -> macOS -> App (SwiftUI, Swift, 14.2)
2. Move sources into AntiBleedApp/App, AntiBleedApp/UI, AntiBleedApp/Audio per Docs/Architecture.md
3. Add AECBridge as a static library target (ObjC++) and AntiBleedDriver as a HAL plug-in target
4. This README.md is then removed/replaced by the real project.pbxproj

See phases/PHASE-0-repo-and-build-skeleton.md Step 3.
