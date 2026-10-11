# idp-gitops

What runs in the IDP's Kubernetes cluster, as files. Argo CD watches this repository and makes
the cluster match it; nothing is applied by hand. Terraform (`idp-infra`) installs Argo CD and
nothing else: every controller, every policy and every application in the cluster comes from
here.

It is one of five repositories of the platform:

| Repository | Role |
|---|---|
| [idp-infra](https://github.com/surya-idp/idp-infra) | Terraform for AWS, `make up` / `make down`, the end-to-end test |
| **idp-gitops** (this one) | What runs in the cluster |
| [idp-portal](https://github.com/surya-idp/idp-portal) | Backstage, the templates that open pull requests here |
| [idp-platform](https://github.com/surya-idp/idp-platform) | The CI workflow every template service calls |
| [feature-flag-service](https://github.com/surya-idp/feature-flag-service) | The platform's first application, the flag API |

## Three rules

1. **`main` only changes through a pull request with the `validate` check green.** A ruleset
   enforces it (no force-push, no deletion). One actor bypasses it: the GitHub App `idp-ci-bot`,
   which Argo CD Image Updater uses to commit image tags. Backstage opens a pull request like a
   person and turns on GitHub auto-merge, so its changes pass `validate` too.
2. **No secret is in this repository.** A workload declares an `ExternalSecret`; the External
   Secrets Operator reads the value from AWS Secrets Manager and creates the Kubernetes Secret
   in the cluster.
3. **No file names an IAM role.** Pods get AWS permissions through EKS Pod Identity associations
   that `idp-infra` creates.

## Layout

```
platform/
  argocd-apps/      The Applications. The root Application (created by idp-infra/40-platform)
                    syncs everything in this folder: "app of apps".
  cluster/          Cluster-wide pieces: the secret store (External Secrets -> Secrets Manager),
                    PriorityClasses, Backstage's read-only cluster role, the flag API's right
                    to verify ServiceAccount tokens
  db-operator/      Credentials for the database operator. The only place the RDS master
                    password is read
  image-updater/    Argo CD Image Updater: a newer image in ECR -> a tag commit here
  kyverno/          The eight admission policies
  monitoring/       What the monitoring stack does for us: which pods are scraped, the alert
                    rules, the alert receiver, Grafana's login, the service dashboard, and who
                    may connect to the data stores
apps/
  feature-flag-service/   base + overlays dev (deployed), staging and prod (defined, not deployed)
  idp-portal/             Backstage
  <service>/              added by the Backstage python-service template; found by the
                          ApplicationSet, no Application file needed. Holds only what is
                          specific to the service: name, image, port, env, sizes
components/
  golden-path/      The platform's standard for template services, in one place
  public-route/     Opt-in: a path on the shared load balancer
  postgres/         Opt-in: a database and a login of the service's own
tests/
  golden-path-service*/   Sample services that are never deployed, so a change to components/
                          is always checked even when apps/ holds no template service
  kyverno/          One folder per policy: a manifest it must reject and one it must accept
  prometheus/       Unit tests for the alert rules
scripts/            validate.sh and the checkers it runs
```

## What Argo CD installs, and in which order

The root Application deploys in **sync waves**: everything of one wave must be healthy before
the next wave starts. Argo CD deletes in the reverse order.

| Wave | Application | What it is |
|---|---|---|
| -3 | `projects.yaml` | The AppProjects: `default` (locked), `platform`, `apps` |
| -2 | `aws-load-balancer-controller` (chart 3.5.0) | Turns an Ingress into a route on the shared ALB |
| -1 | `external-secrets` (chart 2.11.0) | Brings secrets from AWS Secrets Manager |
| 0 | `platform-cluster` | The folder `platform/cluster` |
| 0 | `kyverno` (chart 3.9.1) + `platform/kyverno` | The policy engine and the policies |
| 0 | `db-operator` (`ext-postgres-operator` 3.0.0) + `platform/db-operator` | Creates databases and logins on the shared PostgreSQL instance |
| 0 | `monitoring-stack` (`kube-prometheus-stack` 91.7.0) + `platform/monitoring` | Prometheus, Grafana, Alertmanager |
| 0 | `monitoring-loki` (7.3.0), `monitoring-alloy` (1.13.0), `monitoring-tempo` (2.4.0) | Logs, the log collector, traces |
| 1 | `image-updater` | Argo CD Image Updater v1.3.1 |
| 1 | `feature-flag-dev`, `idp-portal` | The two platform-owned applications |
| 1 | `golden-path-services` (ApplicationSet) | One Application per `apps/<name>/overlays/dev` |

Inside one template service the same idea is used again: namespace in wave -3, database -2,
database login -1, everything else 0 or later. On removal the Deployment goes first, then the
login, then the database, and the namespace last. The order is not cosmetic: the database
operator drops a login only while its database still exists and is not being deleted.

## How an application gets a new version

No CI pipeline writes to this repository.

1. CI of the application builds an image, scans it, and pushes it to ECR with the commit SHA as
   its tag.
2. Argo CD Image Updater (checks every minute) sees a newer image and commits the tag to the
   application's `overlays/dev/kustomization.yaml`, as `idp-ci-bot`.
3. Argo CD (checks this repository every 60 seconds) rolls it out.

This is the same for the flag API, Backstage and every template service. The updater's rule is
"the image that was built last wins", so the pipelines only push an image for the newest commit
of `main`. With the cluster down nothing is committed; the tag is written at the next start.

## The golden path component

`components/golden-path` is what makes a template service's own files short. A service lists
only what is its own. The component adds what the platform decides for all of them:

- the service's namespace, with its pod security labels and the marker `idp.surya-idp/golden-path`
- a zero-downtime rolling update, a `preStop` wait, graceful shutdown time
- restricted pod security: non-root, read-only root filesystem, no capabilities
- startup, readiness and liveness probes
- spreading over zones, the autoscaling metric, a disruption budget
- the label that makes Prometheus scrape it, and where traces go
- a short-lived token valid only for the flag API, and the flag API's address
- a NetworkPolicy: only the load balancer, Prometheus and the same namespace may connect

Changing a file there changes every service at the next sync, and `validate` renders every
service against the change before it can merge.

## Who changes this repository

| Change | Made by | How |
|---|---|---|
| A new service | Backstage, template `python-service` | A pull request that merges itself when `validate` is green |
| A database for a service | Backstage, template `add-postgres-database` | One line (the `postgres` component), same way |
| Removing a service | Backstage, template `decommission-service` | A pull request deleting `apps/<name>` |
| A new image tag | Argo CD Image Updater | A direct, signed commit by `idp-ci-bot` |
| Everything else | A person | A pull request |

## Validation

`scripts/validate.sh` runs on every pull request and on pushes to `main`
(`.github/workflows/validate.yml`), and locally. It needs `kubectl`, `kubeconform`, `helm`, the
Kyverno CLI, `docker`, and Python 3 with PyYAML.

| Step | What it catches |
|---|---|
| Render every Helm chart an Application installs, with our values | A values change the chart rejects |
| Turn every CRD (from the charts and from this repository) into a schema | (prepares the next step) |
| `kubeconform -strict` on every rendered chart, every overlay, every plain manifest | A wrong field, a wrong type, an unknown kind. The public schema catalog is pinned by commit |
| `alertmanager-check.py` | An Alertmanager route that names a receiver that does not exist |
| `namespace-check.py` | A service that declares a namespace other than its own |
| `policy-test.sh` | Something we deploy breaks a policy, or a policy no longer rejects its bad example |
| `rules-test.sh` | An alert rule with a syntax error, or one that no longer fires (or no longer stays quiet) in its unit test |

Render one folder by hand: `kubectl kustomize apps/feature-flag-service/overlays/dev`

## The admission policies

Kyverno, `platform/kyverno/`. Seven enforce; one reports.

| Policy | Rule |
|---|---|
| `require-non-root` | Containers must not run as root |
| `require-resource-limits` | Every container needs CPU and memory requests and a memory limit |
| `restrict-image-registries` | Images come from this account's ECR only |
| `disallow-latest-tag` | An explicit tag other than `latest`, or a digest |
| `require-labels` | Pods carry `app.kubernetes.io/name` |
| `require-probes` | Deployments have readiness and liveness probes |
| `database-name-matches-namespace` | A service can only ask for a database named like its namespace |
| `verify-image-provenance` (audit) | Images under `svc/` carry build provenance signed by the shared CI workflow |

The provenance policy lists the commits of the shared workflow's releases that count as a
signer. **Every release of `idp-platform` needs its commit added there**, or images built by it
are reported as unattested.

## Looking at the platform (cluster up)

Nothing here has a public address except the applications' routes on the load balancer.

| What | How |
|---|---|
| Grafana (dashboards, logs, traces) | `kubectl -n monitoring port-forward svc/kps-grafana 3000:80`, then http://localhost:3000, user `admin`, password: `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Prometheus (targets, queries) | `kubectl -n monitoring port-forward svc/kps-prometheus 9090`, then http://localhost:9090/targets |
| Alerts that fired | `kubectl -n monitoring logs deploy/alert-receiver` |
| Policy results | `kubectl get policyreport -A` (written about every 10 minutes for running resources) |
| Applications and their state | `kubectl -n argocd get applications` |

## Known limits

- One environment is deployed (dev). The staging and prod overlays of the flag API exist to
  show the structure; nothing deploys them.
- The provenance policy reports, it does not block. The two platform-owned images are not built
  by the attesting workflow.
- The NetworkPolicies control who may connect **to** a workload. Outbound traffic is open.
- Tempo and the Prometheus operator are not behind the monitoring NetworkPolicy; the file says why.
- GitHub cannot call the cluster (it has no public address), so Argo CD polls instead of
  reacting to a webhook: a merge takes up to a minute to be noticed.

The full history of the platform, every decision and every bug, is in
[idp-infra/HANDOVER_DOC.md](https://github.com/surya-idp/idp-infra/blob/main/HANDOVER_DOC.md).
