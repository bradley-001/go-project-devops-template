# Go DevSecOps Template

A GitHub template for Go projects, with a DevSecOps pipeline enforced by GitHub Actions and rulesets.

## Pipeline

Every pull request runs:

- build and unit tests
- lint and format checks
- CodeQL SAST
- vulnerability scanning
- licence scanning and dependency review
- secret detection
- a workflow audit
- SBOM generation

All are required checks. The SBOM is required only into `pre-prod` and `prod`.

## Branches

```plaintext
prod <- pre-prod <- staging <- dev <- issue branches
```

Each branch accepts pull requests only from the branch before it. Issue branches must be named:

```plaintext
<issue_num>-<feature|bugfix|hotfix|docs|integration>-<title>
```

For example `12-bugfix-scrolling-on-homepage`. Dependabot branches are also accepted into `dev`.

## Versions and Releases

- Each push to `prod` tags the next patch version. Minor and major bumps are manual runs of the Tag workflow.
- Releases are run by hand against a version tag, so every release is a state of `prod`.
- Pre-releases are run by hand from `pre-prod` and tagged `v<latest release>-pre-prod.g<short sha>`.
- Only the release owner can bump, release or pre-release, and each run needs their approval.
- Claude Code writes the release notes from the commit log and diff. They are only as good as your commit messages.
- Releases carry GitHub build provenance attestations. The Sigstore bundle is attached for offline verification.
- Multi-arch Docker images are published to GHCR. If you do not need them, remove `dockers_v2` from `.goreleaser.yaml` and the image steps from the release workflows.

## Getting Started

`make configure` runs in two stages. Stage 1 fills the template locally. Stage 2 configures the GitHub repository. Each run picks the stage that is due, and both are safe to re-run.

### 4.1. Install the Prerequisites

| Tool              | Used For                             |
| ----------------- | ------------------------------------ |
| Go                | Building, testing and the CI tooling |
| `uv`              | Installing `zizmor`                  |
| GitHub CLI (`gh`) | API calls and encrypting secrets     |
| `jq`              | Building API request bodies          |
| `ssh-keygen`      | Generating the release deploy key    |

*Arch:*

```bash
sudo pacman -S github-cli jq openssh
```

*Linux Mint:*

```bash
sudo apt install gh jq openssh-client
```

Install Go from [go.dev/dl](https://go.dev/dl/) and `uv` from [docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/). No `gh auth login` is needed.

### 4.2. Create the Repository

On GitHub, select "Use this template", then clone the new repository:

```bash
git clone git@github.com:<owner?>/<repo?>.git ~/Repos/<repo?>
```

### 4.3. Fill the Template

```bash
make -C ~/Repos/<repo?> configure
```

| Prompt                                 | Example                       |
| -------------------------------------- | ----------------------------- |
| GitHub repository                      | `you/my-project`              |
| Project name                           | `my_project`                  |
| Binary name                            | `my-project`                  |
| One-line description                   | `Tails Kubernetes audit logs` |
| Licence, as an SPDX identifier         | `AGPL-3.0-only`               |
| GitHub user allowed to tag and release | `you`                         |

This fills every placeholder, renames `cmd/<BINARY_NAME>` and writes `LICENSE`. To do it by hand, see `CHANGE-INSTRUCTIONS.md`.

### 4.4. Commit and Push

*Review the diff first. The rulesets require signed commits.*

```bash
git -C ~/Repos/<repo?> add -A
git -C ~/Repos/<repo?> commit -S -m "Configure from template"
git -C ~/Repos/<repo?> push origin HEAD
```

### 4.5. Create a Short-Lived Token

Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new):

| Field             | Value                              |
| ----------------- | ---------------------------------- |
| Resource owner    | The repository's owner             |
| Expiration        | Custom, tomorrow                   |
| Repository access | Only select repositories, this one |

Set these repository permissions to Read and write, and leave the rest at No access:

| Permission     | Used For                                                        |
| -------------- | --------------------------------------------------------------- |
| Administration | Settings, rulesets, environments, deploy key, security features |
| Contents       | Creating branches, deleting the old default branch              |
| Environments   | Secrets on the `release` environment                            |
| Secrets        | Repository secrets                                              |

> [!CAUTION] Token Scope
  **Do not use a classic token.** Its `repo` scope grants admin over every repository you can access.

> [!NOTE] Organisation Repositories
  An organisation may need to approve fine-grained tokens before they work.

### 4.6. Gather the Optional Secrets

Configure asks for these. Leave either blank to skip it.

- Claude Code OAuth token, from `claude setup-token`. Without it, releases keep GoReleaser's notes.
- gitleaks licence key, for organisation repositories only. Free from [gitleaks.io](https://gitleaks.io). Without it, secret detection fails.

### 4.7. Configure GitHub

```bash
make -C ~/Repos/<repo?> configure
```

Paste the token when asked. It is held in memory for this run only. You are then asked:

- Whether this is a solo project. Solo projects still require pull requests but no approvals, since nobody can approve their own. Otherwise, how many approvals each pull request needs.
- Whether to delete the old default branch, such as `main`.

Configure then:

- creates `prod`, `pre-prod`, `staging` and `dev`, with `prod` as the default
- allows merge commits only
- turns on Dependabot alerts, secret scanning, push protection and private vulnerability reporting
- turns off Dependabot security updates and CodeQL default setup
- makes the workflow token read-only
- creates the `release` and `release-major` environments, with the release owner approving `release-major`
- generates the release deploy key
- stores the secrets
- applies the rulesets in `.github/rulesets`

A failed step prints a warning naming the setting to fix by hand.

> [!CAUTION] Token Handling
> **Never store the token in `.env`.** That file's `GITHUB_TOKEN` is passed to `zizmor` and needs no scopes.

### 4.8. Delete the Token

Delete it at [fine-grained tokens](https://github.com/settings/personal-access-tokens) once configure finishes.

> [!WARNING] Private Repositories
> CodeQL, dependency review and SARIF upload need GitHub Advanced Security on private repositories, or those checks fail. Scorecard cannot publish results for private repositories.

> [!NOTE] Pull Request Base
> Pull requests open against `prod` by default. Set the base to `dev` for issue branches, or the Branch flow check rejects them.

### 4.9. Reinstall the Tooling

Configure installs the local tooling on each run. To reinstall it after changing a version in the workflows:

```bash
make -C ~/Repos/<repo?> tools
```
