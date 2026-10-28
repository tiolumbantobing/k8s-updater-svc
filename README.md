# k8s-updater

`k8s-updater.sh` updates a deployment's container image or restarts deployments.
Every run checks your session, pins the context and namespace, shows a plan, asks
before changing anything, logs to its own folder and follows the rollout with a
progress bar.

It is a plain bash script and works with the bash 3.2 that ships with macOS.
It only needs `kubectl`.

## Quick start

```bash
./k8s-updater.sh                     # interactive menu
./k8s-updater.sh session             # which cluster/user am I on? (read-only)
./k8s-updater.sh status -n my-ns     # deployments, readiness and images (read-only)
```

Update an image. Do a dry run first, then apply:

```bash
./k8s-updater.sh set-image -n my-ns -d my-deploy \
  -i 123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/my-repo:v1.2.3 --dry-run

./k8s-updater.sh set-image -n my-ns -d my-deploy \
  -i 123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/my-repo:v1.2.3
```

Restart deployments:

```bash
./k8s-updater.sh restart -n my-ns -d api -d worker
./k8s-updater.sh restart -n my-ns --all --dry-run
```

Check or toggle ArgoCD autosync. This only talks to the cluster that runs ArgoCD,
so it also works when the workload cluster is behind a different VPN:

```bash
export ARGOCD_CONTEXT=my-argocd-ctx                         # or pass --argocd-context / -c
./k8s-updater.sh autosync -n my-ns                          # status (read-only)
./k8s-updater.sh autosync off -n my-ns -d my-deploy --dry-run
./k8s-updater.sh autosync off -n my-ns -d my-deploy
./k8s-updater.sh autosync on  -n my-ns -d my-deploy
./k8s-updater.sh autosync off --app my-app                  # name the Application directly
```

## What each run does

1. **Session check.** Shows the context, cluster, API server, kube user and
   identity, and checks that the API server is reachable. The script never runs
   `kubectl config use-context`. Every call passes `--context` explicitly.
2. **Namespace.** It must exist. The script checks that you are allowed to patch
   deployments there.
3. **Plan.** Lists each container that will change as `current -> new`.
   `set-image` only touches containers whose image *repository* matches the
   target image, so sidecars such as `istio-proxy` are left alone. Use
   `-C NAME` to pick a container explicitly.
4. **Confirmation.** You answer `y/N`. For a production context (the name
   contains `prd`, `prod` or `production`) you must type the namespace name, and
   `--yes` does not skip this.
5. **Apply and watch.** Shows a progress bar per deployment:

   ```
   [###################-----------]  66%  updated 2/3  ready 3/3  old pods 1
   ```

   The script stops early on `ImagePullBackOff`, `ErrImagePull`,
   `CrashLoopBackOff`, `CreateContainerConfigError`, `ProgressDeadlineExceeded`
   or a timeout. It then prints the pods, recent events and the exact
   `kubectl rollout undo` command.
6. **Logs.** Each run gets its own folder:

   ```
   logs/20261028-132722_set-image_my-ns/
   ├── run.log      everything shown on screen, with timestamps, without colours
   ├── plan.txt     the planned changes
   ├── before.txt   replicas, revision and images before the change
   └── after.txt    the same after the rollout
   ```

   Snapshots hold names, revisions and images only, never env vars or secrets.
   `logs/` is git-ignored.

## Image formats

| Format | Example |
|---|---|
| tag | `repo/app:v1.2.3` |
| digest | `repo/app@sha256:<64 hex>` |
| tag + digest | `repo/app:v1.2.3@sha256:<64 hex>` |

An image without a tag or digest is rejected. `:latest` is allowed, with a warning.

## Options

| Option | Env var | Meaning |
|---|---|---|
| `-c, --context` | `KUBE_CONTEXT` | kube context (default: current context) |
| `-n, --namespace` | `NAMESPACE` | target namespace |
| `-d, --deployment` | | target deployment, repeatable |
| `-A, --all` | | `set-image`: every deployment running the image's repository. `restart`: every deployment in the namespace |
| `-i, --image` | `TARGET_IMAGE` | target image |
| `-C, --container` | `CONTAINER` | container to update |
| `--dry-run` | | plan plus server-side validation (`--dry-run=server`); nothing is saved |
| `-y, --yes` | | skip `y/N` (not the production confirmation) |
| `--timeout` | `ROLLOUT_TIMEOUT` | seconds to wait per deployment (default 600) |
| `--log-dir` | `LOG_ROOT` | where run folders go (default `./logs`) |
| | `POLL_INTERVAL` | seconds between progress checks (default 3) |
| `--argocd-context` | `ARGOCD_CONTEXT` | context of the cluster running ArgoCD (default: `--context`) |
| `--argocd-namespace` | `ARGOCD_NAMESPACE` | namespace of the ArgoCD Applications (default `argocd`) |
| `--app` | `ARGOCD_APP` | ArgoCD Application to use instead of detecting it |
| | `AUTOSYNC_VERIFY_SECONDS` | how long to watch for a reverted toggle (default 10) |

## ArgoCD autosync

`autosync` reads only the ArgoCD cluster (`--argocd-context`, `-c` or the current
context). ArgoCD lists the Deployments each Application manages in
`.status.resources`, so `-n` is the namespace the deployments run in. That
namespace does not need to exist on the ArgoCD cluster.

```
DEPLOYMENT        APP            DEST CLUSTER   AUTOSYNC  PRUNE  SELF-HEAL  SYNC    HEALTH
web-staging       my-app-stg     my-stg-cluster ON        no     no         Synced  Healthy
web-production    my-app-prd     my-prd-cluster OFF       -      -          Synced  Healthy
-                 my-cron-stg    my-stg-cluster OFF       -      -          Synced  Healthy
```

`-` means the Application deploys to the namespace but manages no Deployment
(for example, only CronJobs).

- **off** removes `spec.syncPolicy.automated` from the Application. It saves the
  old settings (prune, selfHeal, ...) in the Application annotation
  `k8s-updater/autosync-backup`.
- **on** restores those saved settings. If nothing was saved, it enables autosync
  with the ArgoCD defaults (prune and selfHeal off) and warns. If the Application
  is `OutOfSync`, the script warns that turning autosync on syncs it right away
  and reverts manual changes such as a `set-image`.
- **Selection.** Use `-d`, `--app` or `--all`. With several matching
  Applications and no selection, the script asks (menu) or stops (non-interactive).
- **One cluster at a time.** One ArgoCD often serves staging and production with
  the same namespace names. `on`/`off` refuses a selection that spans several
  destination clusters. A destination or app name containing
  `prd`/`prod`/`production` needs the typed confirmation.
- **Reverts.** After the patch, the script re-reads the Application for
  `AUTOSYNC_VERIFY_SECONDS`. If an ApplicationSet or a parent app (app of apps)
  puts autosync back, the run fails. In that case change autosync in git: the
  ApplicationSet values or template. Before applying, the script warns when the
  Application is generated by an ApplicationSet that does not ignore `syncPolicy`
  differences.
- Only `syncPolicy`, sync/health status and metadata are read and logged. The
  Application spec is never logged, because it can hold Helm values with secrets.

`set-image` also reports the autosync state when ArgoCD is reachable from the same
context. With autosync + selfHeal on,
ArgoCD reverts the new image within seconds, so turn autosync off first.

## Notes

- **ArgoCD.** If a deployment is managed by ArgoCD, a manual change shows as
  *OutOfSync*, and the next sync reverts it. The script warns about this and
  shows the autosync state. Update the image tag in the ArgoCD values repo as well.
- **Restart order.** `restart --all` restarts deployments one at a time and
  waits for each. It stops at the first failure, so a bad rollout does not spread.
- After `set-image`, the script records the change in the deployment's
  `kubernetes.io/change-cause` annotation, so `kubectl rollout history` shows
  who changed what.
