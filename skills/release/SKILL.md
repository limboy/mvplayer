---
name: release
description: Determine the next version and run the GitHub Actions Owl release pipeline.
---

Cut a new release of Owl. See the README's "Releasing" section. This
skill derives the version from the tag history and CHANGELOG.md, then
triggers the tag-push GitHub Actions pipeline that builds, signs, notarizes,
and publishes it.

Owl commits are plain imperative sentences with no `[scope]` prefix and
no `feat:`/`fix:` conventional-commit markers, unlike some other repos. Do
not invent or assume such a convention here — use full, unfiltered commit
history and your own judgment, confirmed with the user.

## Instructions

### Step 1: Verify prerequisites

1. GitHub CLI authentication works (`gh auth status`).
2. The repository has every secret required by
   `.github/workflows/release.yml` / `scripts/release-ci.sh`. Check names
   with `gh secret list`; never print secret values:
   - `APPLE_TEAM_ID`
   - `ASC_ISSUER_ID`
   - `ASC_KEY_ID`
   - `ASC_PRIVATE_KEY`
   - `MACOS_CERTIFICATE_P12_BASE64`
   - `SIGNING_IDENTITY_NAME`
   - `SPARKLE_ED_PRIVATE_KEY`
   - `MACOS_CERTIFICATE_PASSWORD` is optional when the exported P12 has no
     password.
   If any required secret is missing, stop and tell the user which one.
3. Working tree clean (`git status --porcelain`). If dirty, stop and ask the
   user to commit or stash.
4. On the `main` branch. If not, stop.
5. Pull the latest `origin/main` with `git pull --ff-only` before preparing
   the release.

### Step 2: Determine the next version

1. Get the latest tag: `git tag -l 'v*' | sort -V | tail -1`.
2. Read `CHANGELOG.md`. If its topmost dated section (`## [X.Y.Z] - ...`,
   skipping `## [Unreleased]`) is *not* yet tagged (no matching `vX.Y.Z` tag
   exists), that section's version **is** the next version — it was already
   drafted and just needs publishing. Skip straight to Step 3 with that
   version; no new changelog drafting needed.
3. Otherwise, get commits since the latest tag:
   `git log <latest_tag>..HEAD --oneline --format='%s'`. If there are none,
   stop: "No commits since <tag>. Nothing to release."
4. Judge the version bump from what the commits actually changed (new
   user-facing capability → minor; fixes/internal/docs only → patch;
   anything that changes existing behavior in a way users would notice as
   incompatible → ask explicitly). Because this repo has no commit-scoping
   convention to lean on mechanically, always confirm with the user via
   `AskUserQuestion` rather than deciding silently:
   - question: "Commits since the last release don't follow a strict
     convention here — what version should this release be?"
   - header: "Release version"
   - multiSelect: false
   - options: "Patch (X.Y.Z+1)", "Minor (X.Y+1.0)", "Major (X+1.0.0)", "Custom"

### Step 3: Confirm the version

Confirm before proceeding. Show the tag (`v<VERSION>`) and the commit list
(or, if reusing an already-drafted CHANGELOG section, that section's
entries). Use `AskUserQuestion`:
- question: "Release as <TAG>? Commits included:\n<commit list>"
- header: "Confirm release"
- multiSelect: false
- options:
  - "Yes, release <TAG>"
  - "Use a different version"
  - "Cancel"

If "Use a different version", ask for the version. If "Cancel", stop.

### Step 3.5: Update the changelog

Skip this step entirely if Step 2 found an already-drafted, untagged
CHANGELOG section for this version.

1. Check if `CHANGELOG.md` has an `## [Unreleased]` section with content.
2. If `## [Unreleased]` is empty or missing, draft entries from the commit
   list gathered in Step 2:
   - **Rewrite each entry user-facing.** Don't echo commit messages verbatim
     — describe what changed from the user's perspective.
   - Bad: "Hide add-folder action outside root"
   - Good: "Hide the Add Folder button when browsing inside a folder,
     not just at the library root"
   - Drop entries with no user-visible impact (internal refactors, CI/build
     plumbing, skill/doc-only changes).
   - Keep entries succinct — one line each, no technical jargon.
   - Confirm the drafted entries with `AskUserQuestion` before writing them.
3. Rename `## [Unreleased]` to `## [VERSION] - YYYY-MM-DD` (today's date).
4. Add a new empty `## [Unreleased]` above it.

### Step 4: Update version strings

Skip this step entirely if `project.yml` already has
`MARKETING_VERSION: "<VERSION>"` and it's already committed (the
already-drafted-section case from Step 2).

1. Edit `project.yml`. Update `MARKETING_VERSION` under the `Owl`
   target's base settings.
2. Commit and push:
   ```bash
   git add project.yml CHANGELOG.md
   git commit -m "Prepare v<VERSION> release"
   git push origin main
   ```

### Step 5: Trigger and monitor the GitHub release

```bash
git tag "v<VERSION>"
git push origin "v<VERSION>"
```

The tag triggers `.github/workflows/release.yml`, which runs
`scripts/release-ci.sh` and handles: `xcodegen` → vendor libmpv/ffmpeg
(`scripts/bundle-mpv-deps.sh`) → archive → export → DMG → notarize → staple
→ latest-only Sparkle appcast → GitHub Release. `release-ci.sh` itself
refuses to run if `CHANGELOG.md` has no entry for the version, so Step 3.5
isn't just cosmetic.

Find the run whose `headSha` matches the tag and watch it to completion:

```bash
gh run list --workflow release.yml --event push --limit 5 \
  --json databaseId,headSha,status,conclusion,url
gh run watch <RUN_ID> --exit-status
```

On failure, inspect the failed step and report the root cause. Do NOT retry
automatically.

### Step 6: Push and report

Ensure all commits are on the remote:
```bash
git push
```

Tell the user:
- Version released
- Link: `https://github.com/limboy/owl/releases/tag/v<VERSION>`
- That existing installs will pick this up via Sparkle's automatic check (or
  immediately via the app's "Check for Updates…" menu item), since
  `SUFeedURL` always points at `releases/latest/download/appcast.xml`.

## Important Rules

- ALWAYS confirm the version before proceeding
- NEVER tag a release if the working tree is dirty or `main` has not been
  pushed
- NEVER skip the changelog update, even though `release-ci.sh` would also
  catch a missing entry — catching it here saves a ~30 minute CI round trip
- If the GitHub Actions run fails, do NOT blindly retry. Report the error
  and stop. Retry is only okay after the root cause is identified and fixed
  (e.g. a bug in the script or a missing credential). Never retry on an
  unexplained or transient-looking failure without diagnosing it first.
- The tag-triggered GitHub Actions workflow is the canonical publishing
  path. `scripts/release.sh --dry-run <version>` remains available for local
  build verification only; never run the local publishing path (without
  `--dry-run`) after pushing a release tag — that would create a second,
  differently-signed DMG under the same version.
- Do not invent a commit-scope filter (`[mac]`, `feat:`, etc.) for this repo
  — it doesn't use one. Always confirm the version bump with the user
  instead of inferring it silently.
