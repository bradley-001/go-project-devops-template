# Change Instructions

`make configure` fills these placeholders. Replace them by hand only if you cannot run it.

```plaintext
<PROJECT_NAME>                  # Letters, digits and underscores only
<BINARY_NAME>                   # Lowercase letters, digits and dashes only
<GITHUB_ADDRESS>                # i.e. github.com/you/my-project-123
<OPENCONTAINERS_ADDRESS>        # i.e. ghcr.io/you/my-project-123, lowercase
<OPENCONTAINERS_DESCRIPTION>    # A terse description, without " or \
<OPENCONTAINERS_SOURCE>         # i.e. https://github.com/you/my-project-123
<OPENCONTAINERS_LICENSE_SHORT>  # SPDX identifier, i.e. AGPL-3.0-only
<RELEASE_OWNER>                 # GitHub username, without @
```

Also:

- Rename `cmd/<BINARY_NAME>` to `cmd/<binary-name?>`.
- Add a `LICENSE` file. GoReleaser packages it and fails without it.
