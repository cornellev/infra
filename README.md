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
2. In the Tailscale admin console, create two federated identities for this repo. This repo uses
   GitHub's immutable OIDC subject, which carries the org and repo IDs
   (`gh api repos/cornellev/infra/actions/oidc/customization/sub` shows the prefix):
   - `infra gitops test`: scopes `policy_file:read`, `devices:core:read`,
     `devices:posture_attributes:read`, subject
     `repo:cornellev@157062924/infra@1409428931:pull_request`
   - `infra gitops apply`: scopes `policy_file`, `devices:core:read`,
     `devices:posture_attributes`, subject
     `repo:cornellev@157062924/infra@1409428931:environment:tailscale-apply`
3. Add repo variables (not secrets), using the names from Tailscale's GitOps docs:
   `TS_TAILNET` (from the admin console's General settings page), and `TS_OAUTH_ID` and
   `TS_AUDIENCE` from the test identity. In the `tailscale-apply` environment, add `TS_OAUTH_ID`
   and `TS_AUDIENCE` again with the apply identity's values. Environment variables override repo
   ones, so only the `apply` job gets the identity that can write. None is a credential:
   Tailscale only accepts a GitHub-signed token from this repo.
4. Turn on the admin console's warning that the policy is managed externally. Edits made there
   are overwritten on the next push to `main`.

`tailscale/policy.hujson` replaces the live policy on every push to `main` that passes its tests.
Change it through a PR, so the `test` job checks it first.
