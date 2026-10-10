# idp-gitops

GitOps source of truth for the IDP EKS cluster. Argo CD watches this repo; nothing is
applied by hand.

```
platform/
  argocd-apps/      App-of-apps: the root Application (created by idp-infra/40-platform)
                    syncs every Application in here.
    platform-cluster.yaml   wave 0 -> platform/cluster
    feature-flag-dev.yaml   wave 1 -> apps/feature-flag-service/overlays/dev
    idp-portal.yaml         wave 1 -> apps/idp-portal/overlays/dev (Backstage, port-forward only)
    image-updater.yaml      wave 1 -> platform/image-updater
    golden-path-services.yaml  ApplicationSet: one Application per apps/<name>/overlays/dev
  cluster/          ClusterSecretStore (ESO -> AWS Secrets Manager, via IRSA), PriorityClass
  image-updater/    Argo CD Image Updater: new ECR image of a golden-path service -> commits
                    newTag to its dev overlay as idp-ci-bot (ECR login via IRSA)
  kyverno/          Policies. NOT synced until Kyverno is installed (Step 33).
apps/feature-flag-service/
  base/             Deployment, Service, Ingress, ExternalSecret, migration Job, HPA, PDB
  overlays/dev/     DEPLOYED, automated sync. CI updates newTag here.
  overlays/staging/ Defined, not deployed.
  overlays/prod/    Defined, not deployed. Manual sync when enabled. PDB minAvailable 2.
apps/idp-portal/    Backstage (image from github.com/surya-idp/idp-portal CI)
apps/<service>/     added by the Backstage python-service template (a PR that merges itself
                    once `validate` is green); found by the ApplicationSet, no Application file.
                    Holds only what is specific to the service (name, image, port, env, sizes).
components/
  golden-path/      the platform's standard for those services, in one place: zero-downtime
                    rollout, restricted pod security, probes, zone spreading, HPA metric, PDB
  public-route/     opt-in: a path on the shared ALB
tests/golden-path-service/  never deployed; a sample service so `validate` checks every
                    change to components/ even when apps/ holds no golden-path service
scripts/validate.sh render every overlay + schema-check it (CI required check)
```

No `kind: Secret` lives in this repo: ESO creates `feature-flag-secrets` at runtime from
AWS Secrets Manager (`idp/db-creds`, `idp/jwt-secret`, `idp/valkey`).

Render locally: `kubectl kustomize apps/feature-flag-service/overlays/dev`

## Validation and branch rules

Every push and PR runs `scripts/validate.sh` (`.github/workflows/validate.yml`): each overlay is
rendered with Kustomize and checked with kubeconform (strict) against the Kubernetes 1.35 and
CRD schemas. `main` is protected by a ruleset: no force-push or deletion, and changes land
through a PR with the `validate` check green. Only the `idp-ci-bot` App bypasses the ruleset
(image tag commits). Backstage opens a PR like a human and turns on GitHub auto-merge, so
GitHub merges it only when `validate` passes.
