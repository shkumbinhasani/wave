# Changesets

This project uses [changesets](https://github.com/changesets/changesets) to manage versioning and changelogs.

To add a changeset, create a new markdown file in this directory:

```
.changeset/my-change.md
```

With the format:

```md
---
"wave": patch
---

Description of the change.
```

Use `patch` for fixes, `minor` for features, `major` for breaking changes.
