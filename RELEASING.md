# Releasing UU RemoteDroid

The in-app updater consumes the **ZIP + `.sha256`** pair from the latest stable
GitHub release. The DMG is for first-time installation.

## Checklist

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in
   `Support/Info.plist`. The tag must be `v` plus that version.
2. Run `make test`.
3. Build and verify the assets:

   ```bash
   make release
   ```

   This builds and signs the app, refuses to continue unless the signature
   carries the UULabs Team ID (`V726L7NR7H`) and the bundle identifier
   `au.com.uulabs.remotedroid`, then writes to `dist/`:

   - `UU-RemoteDroid-<version>.zip` and `.zip.sha256`
   - `UU-RemoteDroid-<version>.dmg` and `.dmg.sha256`

4. Commit and push the source changes.
5. Tag and publish the release with all four assets:

   ```bash
   VERSION="1.7.0"
   git tag -a "v$VERSION" -m "UU RemoteDroid $VERSION"
   git push origin "v$VERSION"

   gh release create "v$VERSION" \
     "dist/UU-RemoteDroid-$VERSION.zip" \
     "dist/UU-RemoteDroid-$VERSION.zip.sha256" \
     "dist/UU-RemoteDroid-$VERSION.dmg" \
     "dist/UU-RemoteDroid-$VERSION.dmg.sha256" \
     --title "UU RemoteDroid $VERSION" \
     --notes-file path/to/release-notes.md \
     --latest
   ```

The GitHub credential used for `gh release create` needs **Contents: write**
permission. If the release already exists, use `gh release upload … --clobber`.

Drafts and pre-releases are ignored by the updater, so a release can be staged
as a draft and published once its assets are checked.
