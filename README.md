# idp-gitops

GitOps source of truth for the IDP EKS cluster. Argo CD watches this repo; nothing is
applied by hand. Terraform (idp-infra) installs Argo CD and nothing else: every controller
and every app in the cluster comes from here. No file here names an IAM role: pods get AWS
permissions through EKS Pod Identity associations in idp-infra.

```
platform/
  argocd-apps/      App-of-apps: the root Application (created by idp-infra/40-platform)
                    syncs every Application in here.
    platform-cluster.yaml   wave 0 -> platform/cluster
    feature-flag-dev.yaml   wave 1 -> apps/feature-flag-service/overlays/dev
    idp-portal.yaml         wave 1 -> apps/idp-portal/overlays/dev (Backstage, port-forward only)
    projects.yaml           wave -3 -> AppProjects default (locked), platform, apps
    platform-controllers.yaml  wave -2 AWS Load Balancer Controller, wave -1 External Secrets
    kyverno.yaml            wave 0 -> Helm chart kyverno + platform/kyverno (policies)
    monitoring-stack.yaml   wave 0 -> kube-prometheus-stack (Prometheus, Grafana, Alertmanager) + platform/monitoring
    monitoring-logs.yaml    wave 0 -> Loki (stores logs) and Alloy (collects them)
    monitoring-traces.yaml  wave 0 -> Tempo (traces)
    db-operator.yaml        wave 0 -> Helm chart ext-postgres-operator + platform/db-operator
    image-updater.yaml      wave 1 -> platform/image-updater
    golden-path-services.yaml  ApplicationSet: one Application per apps/<name>/overlays/dev
  cluster/          ClusterSecretStore (ESO -> AWS Secrets Manager), PriorityClass
  db-operator/      credentials for the database operator (the operator itself is a Helm chart,
                    see argocd-apps/db-operator.yaml). The only place the RDS master password lives.
  image-updater/    Argo CD Image Updater: new ECR image of a golden-path service -> commits
                    newTag to its dev overlay as idp-ci-bot
  monitoring/       what the monitoring stack does for us: which pods are scraped (label
                    idp.surya-idp/metrics), alert rules, the alert receiver, Grafana's login and
                    the per-service dashboard. The stack is four charts: argocd-apps/monitoring-*.yaml
  kyverno/          the admission policies (Kyverno itself is a Helm chart, argocd-apps/kyverno.yaml):
                    non-root, resource requests/limits, ECR-only images, no `latest`, service
                    label, probes, database name = namespace, signed build provenance (audit)
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
                    rollout, restricted pod security, probes, zone spreading, HPA metric, PDB,
                    metrics and tracing, and a NetworkPolicy (only the load balancer,
                    Prometheus and the same namespace may connect)
  public-route/     opt-in: a path on the shared ALB
  postgres/         opt-in: a database and a login of its own, as DATABASE_* env vars
tests/prometheus/   promtool unit tests: each alert fires on bad data, stays quiet on good data
tests/kyverno/      one folder per policy: a manifest it must reject, and one it must accept
tests/golden-path-service/  never deployed; a sample service so `validate` checks every
                    change to components/ even when apps/ holds no golden-path service
scripts/validate.sh render every overlay and every Helm chart an Application installs,
                    schema-check the result, then run the policy tests (CI required check)
scripts/rules-test.sh   promtool: alert rule syntax and unit tests
scripts/policy-test.sh  Kyverno CLI: everything deployed passes the policies; each policy
                    rejects its bad example
```

No `kind: Secret` lives in this repo: ESO creates `feature-flag-secrets` at runtime from
AWS Secrets Manager (`idp/jwt-secret`, `idp/valkey`).

Databases: no app uses the RDS master user. An app declares a `Postgres` and a `PostgresUser`
resource (see `apps/*/base/database.yaml`, or the `postgres` component for template services);
the database operator creates the database and a login for it and writes the Secret into the
app's namespace. `idp/db-creds` (master) is read only in namespace `db-operator`.

Render locally: `kubectl kustomize apps/feature-flag-service/overlays/dev`

## Validation and branch rules

Every push and PR runs `scripts/validate.sh` (`.github/workflows/validate.yml`): each overlay is
rendered with Kustomize and checked with kubeconform (strict) against the Kubernetes 1.35 and
CRD schemas. `main` is protected by a ruleset: no force-push or deletion, and changes land
through a PR with the `validate` check green. Only the `idp-ci-bot` App bypasses the ruleset
(image tag commits). Backstage opens a PR like a human and turns on GitHub auto-merge, so
GitHub merges it only when `validate` passes.

## Looking at the platform (cluster up)

| What | How |
|---|---|
| Grafana (dashboards, logs, traces) | `kubectl -n monitoring port-forward svc/kps-grafana 3000:80` -> http://localhost:3000, user `admin`, password: `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Prometheus (targets, queries) | `kubectl -n monitoring port-forward svc/kps-prometheus 9090` -> http://localhost:9090/targets |
| Alerts that fired | `kubectl -n monitoring logs deploy/alert-receiver` |
| Policy results | `kubectl get policyreport -A` |
