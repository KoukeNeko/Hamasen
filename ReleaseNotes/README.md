# Release notes

One folder per release, named as its tag without the `v`: `1.1` for `v1.1`,
`1.1-beta.1` for `v1.1-beta.1`. The part before any `-` must equal
`MARKETING_VERSION`, which the release checks.

```
ReleaseNotes/
└── 1.1/
    ├── github.md          the GitHub release's description (Markdown)
    └── appstore/          "What's New in This Version" on the App Store
        ├── en-US.txt
        ├── ja.txt
        ├── ko.txt
        ├── zh-Hans.txt
        └── zh-Hant.txt
```

- `github.md` is required.
- `appstore/` is optional. When present it needs all five locales, plain
  text, at most 4,000 characters each. Leave it out for the app's first
  version, which the App Store takes no "What's New" for.

Check the notes before tagging:

```bash
swift scripts/release-notes.swift check 1.1
```

## Releasing

1. Set `MARKETING_VERSION` and add the folder for it.
2. Merge to `main`. The App Store build is uploaded as before.
3. Tag the merge and push the tag:

   ```bash
   git tag -s v1.1 -m "Hamasen 1.1" && git push origin v1.1
   ```

The **Release** workflow then builds a Developer ID copy, has Apple notarize
it, publishes the GitHub release with `Hamasen-<version>.dmg`, and writes the
App Store notes into that version on App Store Connect. A tag with a `-`
(`v1.1-beta.1`) is published as a pre-release and sends no App Store notes.
