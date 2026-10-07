# infra

Setup for club machines and the club tailnet `tail4ccb95.ts.net`. Car code stays in each car's repo.

- `pi-image/`: SD card image for the Pi 4 and Pi 5. See its README.
- `tailscale/policy.hujson`: the tailnet policy. `.github/workflows/tailscale.yml` tests it on
  every PR and applies it on push to `main`.

The handoff checklist, how-tos (join the tailnet, register a Pi on RedRover, flash a card), and
the `cev-router` notes live in Confluence.

## Tailscale GitOps setup

PR runs can rewrite the workflow, so they get an identity that can only read and validate the
policy. Only the `apply` job, in an environment that deploys from `main` alone, can write it.

1. In GitHub, create the environment `tailscale-apply` and limit its deployment branches to
   `main`. Add a ruleset on `main` that requires a reviewed PR.
2. In the Tailscale admin console, create two federated identities for this repo:
   - test: scopes `policy_file:read`, `devices:core:read`, `devices:posture_attributes:read`,
     subject matching this repo's pull requests
   - apply: scopes `policy_file`, `devices:core:read`, `devices:posture_attributes`, subject
     matching the `tailscale-apply` environment
3. Add the test identity's client ID and audience as repo variables `TS_TEST_OAUTH_ID` and
   `TS_TEST_AUDIENCE`. Add the apply identity's as `TS_OAUTH_ID` and `TS_AUDIENCE`, as variables
   of the `tailscale-apply` environment. None is a credential: Tailscale only accepts a
   GitHub-signed token from this repo.
4. Turn on the admin console's warning that the policy is managed externally. Edits made there
   are overwritten on the next push to `main`.

`tailscale/policy.hujson` replaces the live policy on every push to `main` that passes its tests.
Change it through a PR, so the `test` job checks it first.
