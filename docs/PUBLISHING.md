# Publishing Checklist

Use this checklist when publishing MacUtil to GitHub.

## 1. Confirm Project Metadata

- Confirm repository owner and name.
- Confirm the MIT license choice.
- Confirm the copyright holder in `LICENSE`.
- Decide whether the first public release is source-only or includes a signed
  app bundle.

## 2. Prepare The Working Tree

The repo now includes a `.gitignore` for generated and local files:

- `.build/`
- `build/`
- `.DS_Store`
- `.claude/`
- `.codex/`
- logs and editor state

Optional local cleanup before the first commit:

```bash
find . -name .DS_Store -delete
rm -rf .build build
```

The build artifacts can always be recreated with:

```bash
Scripts/run.sh
```

## 3. Initialize Git

```bash
git init
git add .
git commit -m "Initial open-source release"
git branch -M main
```

## 4. Create The GitHub Repository

With GitHub CLI:

```bash
gh repo create MacUtil --public --source=. --remote=origin --push
```

Without GitHub CLI:

```bash
git remote add origin git@github.com:OWNER/MacUtil.git
git push -u origin main
```

Replace `OWNER` with the chosen GitHub user or organization.

## 5. Configure GitHub

Recommended repository settings:

- Enable private vulnerability reporting.
- Protect the `main` branch once collaborators are involved.
- Require the build workflow before merging pull requests.
- Add repository topics such as `macos`, `swift`, `appkit`, `window-manager`,
  `screencapturekit`, and `menu-bar`.

## 6. Optional Release Artifacts

For source-only releases, tag the commit:

```bash
git tag v0.1.0
git push origin v0.1.0
```

For binary releases, prefer a Developer ID signed and notarized archive. The
current build script signs the app but does not notarize or package a release
archive.
