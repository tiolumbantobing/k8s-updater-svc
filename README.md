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

## Notes

- **ArgoCD.** If a deployment is managed by ArgoCD, a manual change shows as
  *OutOfSync*, and the next sync reverts it. The script warns about this.
  Update the image tag in the ArgoCD values repo as well.
- **Restart order.** `restart --all` restarts deployments one at a time and
  waits for each. It stops at the first failure, so a bad rollout does not spread.
- After `set-image`, the script records the change in the deployment's
  `kubernetes.io/change-cause` annotation, so `kubectl rollout history` shows
  who changed what.
