#!/usr/bin/env bash
# k8s-updater.sh - structured image update / restart for Kubernetes deployments.
#
# Every run checks the kube session, pins the context and namespace, asks for
# confirmation, logs to its own folder under ./logs and watches the rollout
# with a progress bar. Works with the bash 3.2 that ships with macOS.
#
# Run ./k8s-updater.sh --help for usage.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (each can be overridden by an environment variable or a flag)
# ---------------------------------------------------------------------------
TARGET_IMAGE="${TARGET_IMAGE:-}"            # repo:tag | repo@sha256:... | repo:tag@sha256:...
KUBE_CONTEXT="${KUBE_CONTEXT:-}"            # empty = current kubectl context
NAMESPACE="${NAMESPACE:-}"
CONTAINER="${CONTAINER:-}"                  # empty = containers whose image repo matches TARGET_IMAGE
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600}"   # seconds to wait for each rollout
POLL_INTERVAL="${POLL_INTERVAL:-3}"         # seconds between progress checks
LOG_ROOT="${LOG_ROOT:-$(cd "$(dirname "$0")" && pwd)/logs}"

# Contexts matching this pattern are treated as production (stricter confirmation)
PROD_CONTEXT_PATTERN='(^|[-_/.])(prd|prod|production)([-_/.]|$)'
# Pod waiting reasons that will not fix themselves
FATAL_WAIT_REASONS='ImagePullBackOff ErrImagePull InvalidImageName CrashLoopBackOff CreateContainerConfigError CreateContainerError'

VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"

COMMAND=""
DRY_RUN=0
ASSUME_YES=0
ALL=0
DEPLOYMENTS=()
RUN_DIR=""
LOG_FILE=""
IS_PROD=0
INTERACTIVE=0   # 1 inside the menu: prompts are allowed even without a tty

# ---------------------------------------------------------------------------
# Output and logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Plain text goes to the log file, coloured text to the terminal
_log() {
  local level=$1 colour=$2; shift 2
  local msg="$*"
  printf '%s%-5s%s %s\n' "$colour" "$level" "$C_RESET" "$msg"
  if [[ -n "$LOG_FILE" ]]; then printf '%s %-5s %s\n' "$(ts)" "$level" "$msg" >> "$LOG_FILE"; fi
}
info()  { _log INFO  "$C_BLUE" "$@"; }
ok()    { _log OK    "$C_GREEN" "$@"; }
warn()  { _log WARN  "$C_YELLOW" "$@"; }
error() { _log ERROR "$C_RED" "$@"; }
die()   { error "$@"; exit 1; }

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"
  if [[ -n "$LOG_FILE" ]]; then printf '\n%s == %s ==\n' "$(ts)" "$*" >> "$LOG_FILE"; fi
}

# Print a block of text to the terminal and the log
log_block() {
  local text=$1
  [[ -z "$text" ]] && return 0
  printf '%s\n' "$text"
  if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$text" >> "$LOG_FILE"; fi
}

# kubectl, always pinned to the chosen context
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# Run a mutating kubectl command: echo it, log it, honour --dry-run
k_change() {
  local cmd_text="kubectl --context $KUBE_CONTEXT $*"
  local out rc=0
  if [[ $DRY_RUN -eq 1 ]]; then
    cmd_text="$cmd_text --dry-run=server"
    printf '%s$ %s%s\n' "$C_DIM" "$cmd_text" "$C_RESET"
    [[ -n "$LOG_FILE" ]] && printf '%s $ %s\n' "$(ts)" "$cmd_text" >> "$LOG_FILE"
    out=$(k "$@" --dry-run=server 2>&1) || rc=$?
  else
    printf '%s$ %s%s\n' "$C_DIM" "$cmd_text" "$C_RESET"
    [[ -n "$LOG_FILE" ]] && printf '%s $ %s\n' "$(ts)" "$cmd_text" >> "$LOG_FILE"
    out=$(k "$@" 2>&1) || rc=$?
  fi
  log_block "$out"
  return $rc
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${C_BOLD}$SCRIPT_NAME $VERSION${C_RESET} - update images / restart Kubernetes deployments with checks and logs

Usage:
  $SCRIPT_NAME                      interactive menu
  $SCRIPT_NAME session  [-c CTX] [-n NS]
  $SCRIPT_NAME status   -n NS [-c CTX]
  $SCRIPT_NAME set-image -n NS -i IMAGE (-d DEPLOY ... | --all) [-C CONTAINER] [--dry-run]
  $SCRIPT_NAME restart  -n NS (-d DEPLOY ... | --all) [--dry-run]

Commands:
  session      Show which cluster/user you are on and check access (read-only)
  status       List deployments, readiness and images in a namespace (read-only)
  set-image    Replace a container image (tag or digest) and wait for the rollout
  restart      Rollout-restart deployments one by one and wait for each
  menu         Interactive menu (default when no command is given)

Options:
  -c, --context CTX       kube context to use (default: current context; never changed)
  -n, --namespace NS      target namespace
  -d, --deployment NAME   target deployment, repeatable
  -A, --all               set-image: every deployment that runs the image's repository
                          restart:   every deployment in the namespace
  -i, --image IMAGE       target image: repo:tag | repo@sha256:<digest> | repo:tag@sha256:<digest>
  -C, --container NAME    container to update (default: containers whose image repository
                          matches IMAGE)
      --dry-run           show the plan and validate it on the API server; change nothing
  -y, --yes               skip the y/N confirmation (production contexts still ask you to
                          type the namespace)
      --timeout SEC       rollout wait per deployment (default: $ROLLOUT_TIMEOUT)
      --log-dir DIR       where run folders are written (default: ./logs)
  -h, --help              this help

Environment variables: TARGET_IMAGE, KUBE_CONTEXT, NAMESPACE, CONTAINER, ROLLOUT_TIMEOUT,
POLL_INTERVAL, LOG_ROOT.

Examples:
  $SCRIPT_NAME session
  $SCRIPT_NAME status -n lms-collection
  $SCRIPT_NAME set-image -n lms-collection -d lms-collection-web-production \\
      -i 097159463413.dkr.ecr.ap-southeast-3.amazonaws.com/ffi-krdv-te-lms-collection:web-v0.0.105 --dry-run
  TARGET_IMAGE=repo/app@sha256:abc... $SCRIPT_NAME set-image -n my-ns --all
  $SCRIPT_NAME restart -n my-ns -d api -d worker
EOF
}

can_prompt() { [[ $INTERACTIVE -eq 1 || -t 0 ]]; }

contains_word() {  # contains_word "a b c" b
  local list=" $1 " word=$2
  [[ "$list" == *" $word "* ]]
}

# Repository part of an image reference (no tag, no digest)
image_repo() {
  local ref=${1%%@*}
  local last=${ref##*/}
  if [[ "$last" == *:* ]]; then
    ref=${ref%:*}
  fi
  printf '%s' "$ref"
}

validate_image() {
  local img=$1
  [[ -n "$img" ]] || die "No target image. Set TARGET_IMAGE or pass -i/--image."
  [[ "$img" != *" "* ]] || die "Image must not contain spaces: '$img'"
  local repo; repo=$(image_repo "$img")
  [[ -n "$repo" && "$repo" != "$img" || "$img" == *@sha256:* ]] \
    || die "Image '$img' has no tag or digest. Use repo:tag, repo@sha256:<digest> or repo:tag@sha256:<digest>."
  if [[ "$img" == *@* ]]; then
    [[ "$img" =~ @sha256:[a-f0-9]{64}$ ]] || die "Digest must be sha256 with 64 hex characters: '$img'"
  fi
  if [[ "${img%%@*}" =~ :latest$ ]]; then
    warn "Tag 'latest' is mutable; prefer an immutable tag or a digest."
  fi
}

confirm() {  # confirm "question"
  local question=$1 answer
  if [[ $IS_PROD -eq 1 ]]; then
    printf '%s%sPRODUCTION%s context %s%s%s.\n' "$C_RED" "$C_BOLD" "$C_RESET" "$C_BOLD" "$KUBE_CONTEXT" "$C_RESET"
    read -r -p "$question Type the namespace '$NAMESPACE' to confirm: " answer
    [[ "$answer" == "$NAMESPACE" ]] || { warn "Confirmation did not match. Nothing changed."; return 1; }
  elif [[ $ASSUME_YES -eq 1 ]]; then
    info "$question --yes given, continuing."
  else
    read -r -p "$question [y/N]: " answer
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]] || { warn "Aborted. Nothing changed."; return 1; }
  fi
  [[ -n "$LOG_FILE" ]] && printf '%s CONFIRMED by %s\n' "$(ts)" "${USER:-unknown}" >> "$LOG_FILE"
  return 0
}

# Create ./logs/<timestamp>_<command>_<namespace>/run.log
start_run_log() {
  local label=$1
  local stamp; stamp=$(date '+%Y%m%d-%H%M%S')
  RUN_DIR="$LOG_ROOT/${stamp}_${label}_${NAMESPACE:-none}"
  mkdir -p "$RUN_DIR"
  LOG_FILE="$RUN_DIR/run.log"
  {
    echo "# k8s-updater $VERSION"
    echo "# started : $(ts)"
    echo "# user    : ${USER:-unknown}@$(hostname -s 2>/dev/null || echo unknown)"
    echo "# command : $SCRIPT_NAME $label"
    echo "# context : $KUBE_CONTEXT"
    echo "# ns      : ${NAMESPACE:-}"
    echo "# dry-run : $DRY_RUN"
  } > "$LOG_FILE"
  info "Logging to $RUN_DIR"
}

# Minimal, non-sensitive snapshot: names, replicas, revision and images only (no env)
snapshot() {  # snapshot before|after deploy...
  local phase=$1; shift
  local d out
  : > "$RUN_DIR/$phase.txt"
  for d in "$@"; do
    out=$(k -n "$NAMESPACE" get deploy "$d" -o jsonpath='{.metadata.name}{"  replicas="}{.spec.replicas}{"  revision="}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"  generation="}{.metadata.generation}{"\n"}{range .spec.template.spec.containers[*]}{"    "}{.name}{"="}{.image}{"\n"}{end}' 2>&1) || true
    printf '%s\n' "$out" >> "$RUN_DIR/$phase.txt"
  done
}

# ---------------------------------------------------------------------------
# 1. Session
# ---------------------------------------------------------------------------
resolve_context() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."
  if [[ -z "$KUBE_CONTEXT" ]]; then
    KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null) || die "No current kubectl context. Pass -c/--context."
  fi
  kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "$KUBE_CONTEXT" \
    || die "Context '$KUBE_CONTEXT' not found in kubeconfig."
  if printf '%s' "$KUBE_CONTEXT" | grep -Eqi "$PROD_CONTEXT_PATTERN"; then IS_PROD=1; else IS_PROD=0; fi
}

check_session() {
  section "Session"
  local cluster server user who
  cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$KUBE_CONTEXT\")].context.cluster}" 2>/dev/null || true)
  user=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$KUBE_CONTEXT\")].context.user}" 2>/dev/null || true)
  server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}" 2>/dev/null || true)
  info "Context   : $KUBE_CONTEXT"
  info "Cluster   : ${cluster:-?}"
  info "API server: ${server:-?}"
  info "Kube user : ${user:-?}"
  if [[ $IS_PROD -eq 1 ]]; then
    warn "This looks like a PRODUCTION context."
  fi
  if ! k version --request-timeout=10s >/dev/null 2>&1; then
    die "Cannot reach the API server with context '$KUBE_CONTEXT' (expired credentials, VPN, or network?)."
  fi
  ok "API server reachable"
  who=$(k auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)
  info "Identity  : ${who:-unknown (auth whoami not available)}"
}

# ---------------------------------------------------------------------------
# 2. Namespace
# ---------------------------------------------------------------------------
choose_namespace() {
  if [[ -z "$NAMESPACE" ]]; then
    can_prompt || die "No namespace. Pass -n/--namespace."
    read -r -p "Namespace: " NAMESPACE
  fi
  [[ -n "$NAMESPACE" ]] || die "Namespace is required."
  k get namespace "$NAMESPACE" >/dev/null 2>&1 || die "Namespace '$NAMESPACE' not found in context '$KUBE_CONTEXT'."
  local count
  count=$(k -n "$NAMESPACE" get deploy -o name 2>/dev/null | grep -c . || true)
  ok "Namespace '$NAMESPACE' exists ($count deployments)"
}

check_access() {  # check_access verb resource
  if [[ "$(k -n "$NAMESPACE" auth can-i "$1" "$2" 2>/dev/null || true)" == yes ]]; then
    ok "Allowed to $1 $2 in '$NAMESPACE'"
  else
    die "You are not allowed to $1 $2 in '$NAMESPACE' on '$KUBE_CONTEXT'."
  fi
}

list_deployments() { k -n "$NAMESPACE" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }

pick_deployments() {  # interactive: fill DEPLOYMENTS or set ALL=1
  local names=() d choice
  while IFS= read -r d; do [[ -n "$d" ]] && names+=("$d"); done < <(list_deployments)
  [[ ${#names[@]} -gt 0 ]] || die "No deployments in '$NAMESPACE'."
  echo "Deployments in '$NAMESPACE':"
  PS3="Choose a number: "
  select choice in "ALL deployments" "${names[@]}"; do
    if [[ "$REPLY" == 1 ]]; then ALL=1; break
    elif [[ -n "$choice" ]]; then DEPLOYMENTS=("$choice"); break
    fi
    echo "Invalid choice."
  done
}

argocd_warning() {  # argocd_warning deploy
  local marks
  marks=$(k -n "$NAMESPACE" get deploy "$1" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{.metadata.labels.argocd\.argoproj\.io/instance}{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || true)
  if [[ -n "$marks" ]]; then
    warn "'$1' looks managed by ArgoCD/Helm: a manual change shows as OutOfSync and the next sync reverts it. Update the values in git too."
  fi
}

# ---------------------------------------------------------------------------
# 7. Rollout progress
# ---------------------------------------------------------------------------
draw_bar() {  # draw_bar percent label
  local pct=$1 label=$2 width=30 filled empty bar=""
  filled=$(( pct * width / 100 )); empty=$(( width - filled ))
  [[ $filled -gt 0 ]] && bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
  [[ $empty -gt 0 ]] && bar="$bar$(printf '%*s' "$empty" '' | tr ' ' '-')"
  printf '\r  [%s] %3d%%  %s\033[K' "$bar" "$pct" "$label"
}

deploy_selector() {  # label selector string from spec.selector.matchLabels
  k -n "$NAMESPACE" get deploy "$1" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
    | tr -d '{}"' | tr ':' '='
}

pod_problems() {  # prints "pod reason" lines for fatal waiting reasons
  local selector=$1 line pod reason
  k -n "$NAMESPACE" get pods -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.initContainerStatuses[*]}{.state.waiting.reason}{" "}{end}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' 2>/dev/null \
  | while read -r pod rest; do
      for reason in $rest; do
        if contains_word "$FATAL_WAIT_REASONS" "$reason"; then echo "$pod $reason"; fi
      done
    done
}

rollout_diagnostics() {  # rollout_diagnostics deploy selector
  section "Diagnostics for $1"
  log_block "$(k -n "$NAMESPACE" get pods -l "$2" -o wide 2>&1 || true)"
  log_block "$(k -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true)"
  warn "Roll back with: kubectl --context $KUBE_CONTEXT -n $NAMESPACE rollout undo deployment/$1"
}

wait_rollout() {  # wait_rollout deploy
  local d=$1 start now elapsed status desired total updated ready available gen observed reason
  local pct label problems strikes=0 polls=0 selector
  selector=$(deploy_selector "$d")
  start=$(date +%s)
  info "Waiting for '$d' (timeout ${ROLLOUT_TIMEOUT}s)"
  while :; do
    status=$(k -n "$NAMESPACE" get deploy "$d" -o jsonpath='{.spec.replicas} {.status.replicas} {.status.updatedReplicas} {.status.readyReplicas} {.status.availableReplicas} {.metadata.generation} {.status.observedGeneration} {.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null) || status=""
    read -r desired total updated ready available gen observed reason <<< "$status" || true
    desired=${desired:-0}; total=${total:-0}; updated=${updated:-0}; ready=${ready:-0}
    available=${available:-0}; gen=${gen:-0}; observed=${observed:-0}
    # with no status fields the condition reason shifts left; keep it only if it is text
    [[ "$reason" =~ ^[A-Za-z]+$ ]] || reason=""

    if [[ $desired -eq 0 ]]; then
      pct=100
    else
      local done_now=$updated
      [[ $available -lt $done_now ]] && done_now=$available
      pct=$(( done_now * 100 / desired ))
      [[ $pct -gt 100 ]] && pct=100
    fi
    local finished=0
    if [[ $observed -ge $gen && $updated -eq $desired && $available -eq $desired && $total -eq $desired ]]; then
      finished=1; pct=100
    elif [[ $pct -ge 100 ]]; then
      pct=99   # new pods ready, old pods still terminating
    fi
    label="updated $updated/$desired  ready $ready/$desired"
    [[ $total -gt $desired ]] && label="$label  old pods $(( total - desired ))"
    draw_bar "$pct" "$label"

    if [[ $finished -eq 1 ]]; then
      printf '\n'
      ok "'$d' rolled out: $available/$desired available"
      return 0
    fi
    if [[ "$reason" == ProgressDeadlineExceeded ]]; then
      printf '\n'; error "'$d' exceeded its progress deadline"
      rollout_diagnostics "$d" "$selector"; return 1
    fi
    polls=$(( polls + 1 ))
    if [[ -n "$selector" ]]; then
      problems=$(pod_problems "$selector")
      if [[ -n "$problems" ]]; then
        strikes=$(( strikes + 1 ))
        if [[ $strikes -ge 3 ]]; then
          printf '\n'; error "'$d' has pods that will not recover:"
          log_block "$problems"
          rollout_diagnostics "$d" "$selector"; return 1
        fi
      else
        strikes=0
      fi
    fi
    now=$(date +%s); elapsed=$(( now - start ))
    if [[ $elapsed -ge $ROLLOUT_TIMEOUT ]]; then
      printf '\n'; error "'$d' not ready after ${ROLLOUT_TIMEOUT}s"
      rollout_diagnostics "$d" "$selector"; return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_session() {
  resolve_context
  check_session
  if [[ -n "$NAMESPACE" ]]; then
    choose_namespace
    check_access get deployments
    check_access patch deployments
  fi
}

cmd_status() {
  resolve_context
  check_session
  choose_namespace
  section "Deployments in $NAMESPACE"
  k -n "$NAMESPACE" get deploy -o wide
  echo
  k -n "$NAMESPACE" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.template.spec.containers[*]}{"    "}{.name}{" = "}{.image}{"\n"}{end}{end}'
}

# Resolve which deployment/container pairs set-image will touch
build_image_plan() {  # prints "deploy<TAB>container<TAB>current-image" lines
  local target_repo=$1 d line name img
  local targets=()
  if [[ $ALL -eq 1 ]]; then
    while IFS= read -r d; do [[ -n "$d" ]] && targets+=("$d"); done < <(list_deployments)
  else
    targets=(${DEPLOYMENTS[@]+"${DEPLOYMENTS[@]}"})
  fi
  for d in ${targets[@]+"${targets[@]}"}; do
    k -n "$NAMESPACE" get deploy "$d" >/dev/null 2>&1 || die "Deployment '$d' not found in '$NAMESPACE'."
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name=${line%%=*}; img=${line#*=}
      if [[ -n "$CONTAINER" && "$name" == "$CONTAINER" ]]; then
        printf '%s\t%s\t%s\n' "$d" "$name" "$img"
      elif [[ -z "$CONTAINER" && "$(image_repo "$img")" == "$target_repo" ]]; then
        printf '%s\t%s\t%s\n' "$d" "$name" "$img"
      fi
    done < <(k -n "$NAMESPACE" get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"="}{.image}{"\n"}{end}')
  done
}

cmd_set_image() {
  if [[ -z "$TARGET_IMAGE" ]] && can_prompt; then
    read -r -p "Target image (repo:tag or repo@sha256:...): " TARGET_IMAGE
  fi
  validate_image "$TARGET_IMAGE"
  resolve_context
  check_session
  choose_namespace
  if [[ $ALL -eq 0 && ${#DEPLOYMENTS[@]} -eq 0 ]]; then
    can_prompt || die "Choose deployments with -d NAME or --all."
    pick_deployments
  fi
  check_access patch deployments

  local target_repo plan
  target_repo=$(image_repo "$TARGET_IMAGE")
  plan=$(build_image_plan "$target_repo")
  if [[ -z "$plan" ]]; then
    if [[ -n "$CONTAINER" ]]; then
      die "No container named '$CONTAINER' in the selected deployments."
    fi
    die "No container in the selected deployments runs repository '$target_repo'. Use -C/--container to pick one explicitly."
  fi

  start_run_log set-image
  section "Plan"
  info "Target image: $TARGET_IMAGE"
  local d c cur changes=0 plan_text="" deploys_to_wait=""
  while IFS=$'\t' read -r d c cur; do
    if [[ "$cur" == "$TARGET_IMAGE" ]]; then
      plan_text="$plan_text  $d / $c : already $cur (skip)"$'\n'
    else
      plan_text="$plan_text  $d / $c : $cur -> $TARGET_IMAGE"$'\n'
      changes=$(( changes + 1 ))
      contains_word "$deploys_to_wait" "$d" || deploys_to_wait="$deploys_to_wait $d"
    fi
  done <<< "$plan"
  log_block "${plan_text%$'\n'}"
  printf '%s' "$plan_text" > "$RUN_DIR/plan.txt"
  if [[ $changes -eq 0 ]]; then ok "Nothing to change."; return 0; fi
  for d in $deploys_to_wait; do argocd_warning "$d"; done

  # shellcheck disable=SC2086
  snapshot before $deploys_to_wait
  if [[ $DRY_RUN -eq 1 ]]; then
    section "Dry run (server-side validation, nothing is saved)"
  else
    confirm "Apply $changes image change(s) in '$NAMESPACE' on '$KUBE_CONTEXT'?" || return 1
    section "Apply"
  fi
  local failed=0
  while IFS=$'\t' read -r d c cur; do
    [[ "$cur" == "$TARGET_IMAGE" ]] && continue
    k_change -n "$NAMESPACE" set image "deployment/$d" "$c=$TARGET_IMAGE" || failed=1
  done <<< "$plan"
  if [[ $failed -eq 1 ]]; then die "kubectl set image failed (see above). Check $RUN_DIR."; fi
  if [[ $DRY_RUN -eq 1 ]]; then
    ok "Dry run passed. Run again without --dry-run to apply."
    return 0
  fi
  for d in $deploys_to_wait; do
    k -n "$NAMESPACE" annotate --overwrite "deployment/$d" \
      "kubernetes.io/change-cause=k8s-updater set-image $TARGET_IMAGE by ${USER:-unknown}" >/dev/null 2>&1 || true
  done

  section "Rollout"
  local rollout_failed=0
  for d in $deploys_to_wait; do wait_rollout "$d" || rollout_failed=1; done
  # shellcheck disable=SC2086
  snapshot after $deploys_to_wait
  finish "$rollout_failed"
}

cmd_restart() {
  resolve_context
  check_session
  choose_namespace
  if [[ $ALL -eq 0 && ${#DEPLOYMENTS[@]} -eq 0 ]]; then
    can_prompt || die "Choose deployments with -d NAME or --all."
    pick_deployments
  fi
  check_access patch deployments

  local targets=() d
  if [[ $ALL -eq 1 ]]; then
    while IFS= read -r d; do [[ -n "$d" ]] && targets+=("$d"); done < <(list_deployments)
  else
    targets=(${DEPLOYMENTS[@]+"${DEPLOYMENTS[@]}"})
  fi
  [[ ${#targets[@]} -gt 0 ]] || die "No deployments to restart."
  for d in "${targets[@]}"; do
    k -n "$NAMESPACE" get deploy "$d" >/dev/null 2>&1 || die "Deployment '$d' not found in '$NAMESPACE'."
  done

  start_run_log restart
  section "Plan"
  for d in "${targets[@]}"; do log_block "  restart $d"; done
  printf '%s\n' "${targets[@]}" > "$RUN_DIR/plan.txt"
  snapshot before "${targets[@]}"

  if [[ $DRY_RUN -eq 1 ]]; then
    section "Dry run (server-side validation, nothing is saved)"
    for d in "${targets[@]}"; do k_change -n "$NAMESPACE" rollout restart "deployment/$d" || die "Dry run failed for '$d'."; done
    ok "Dry run passed. Run again without --dry-run to restart."
    return 0
  fi
  confirm "Restart ${#targets[@]} deployment(s) in '$NAMESPACE' on '$KUBE_CONTEXT'?" || return 1

  local rollout_failed=0
  for d in "${targets[@]}"; do
    section "Restart $d"
    if ! k_change -n "$NAMESPACE" rollout restart "deployment/$d"; then rollout_failed=1; continue; fi
    if ! wait_rollout "$d"; then
      rollout_failed=1
      if [[ ${#targets[@]} -gt 1 ]]; then warn "Stopping here; remaining deployments were not restarted."; break; fi
    fi
  done
  snapshot after "${targets[@]}"
  finish "$rollout_failed"
}

finish() {
  section "Result"
  if [[ "$1" -eq 0 ]]; then
    ok "Done. Log: $RUN_DIR"
    echo "# finished: $(ts) OK" >> "$LOG_FILE"
  else
    error "Finished with errors. Log: $RUN_DIR"
    echo "# finished: $(ts) FAILED" >> "$LOG_FILE"
    exit 1
  fi
}

# Menu namespace prompt: a typo returns to the menu instead of exiting
menu_choose_namespace() {
  local ns
  read -r -p "Namespace: " ns
  if [[ -n "$ns" ]] && k get namespace "$ns" >/dev/null 2>&1; then
    NAMESPACE=$ns
    ok "Namespace set to '$NAMESPACE'"
  else
    warn "Namespace '${ns}' not found in '$KUBE_CONTEXT'."
    return 1
  fi
}

cmd_menu() {
  INTERACTIVE=1
  resolve_context
  check_session
  local choice
  while :; do
    printf '\n%sMenu%s  (context: %s%s%s, namespace: %s)\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$KUBE_CONTEXT" "$C_RESET" "${NAMESPACE:-not set}"
    echo "  1) Check session"
    echo "  2) Choose namespace"
    echo "  3) Show deployments and images"
    echo "  4) Update image"
    echo "  5) Restart deployment(s)"
    echo "  6) Toggle dry run (now: $([[ $DRY_RUN -eq 1 ]] && echo ON || echo OFF))"
    echo "  q) Quit"
    read -r -p "> " choice || break
    # Actions 3-5 need a namespace; it is remembered for the next actions
    case "$choice" in
      3|4|5) if [[ -z "$NAMESPACE" ]]; then menu_choose_namespace || continue; fi ;;
    esac
    # Each action runs in a subshell so a failed check returns to the menu
    case "$choice" in
      1) ( check_session ) || true ;;
      2) menu_choose_namespace || true ;;
      3) ( cmd_status ) || true ;;
      4) ( DEPLOYMENTS=(); ALL=0; TARGET_IMAGE=""; cmd_set_image ) || true ;;
      5) ( DEPLOYMENTS=(); ALL=0; cmd_restart ) || true ;;
      6) DRY_RUN=$(( 1 - DRY_RUN )) ;;
      q|Q) break ;;
      *) echo "Unknown choice." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
need_value() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "Option $1 needs a value."; }

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then COMMAND=$1; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--context)    need_value "$@"; KUBE_CONTEXT=$2; shift 2 ;;
      -n|--namespace)  need_value "$@"; NAMESPACE=$2; shift 2 ;;
      -d|--deployment) need_value "$@"; DEPLOYMENTS+=("$2"); shift 2 ;;
      -A|--all)        ALL=1; shift ;;
      -i|--image)      need_value "$@"; TARGET_IMAGE=$2; shift 2 ;;
      -C|--container)  need_value "$@"; CONTAINER=$2; shift 2 ;;
      --dry-run)       DRY_RUN=1; shift ;;
      -y|--yes)        ASSUME_YES=1; shift ;;
      --timeout)       need_value "$@"; ROLLOUT_TIMEOUT=$2; shift 2 ;;
      --log-dir)       need_value "$@"; LOG_ROOT=$2; shift 2 ;;
      -h|--help)       usage; exit 0 ;;
      *) die "Unknown option '$1'. See --help." ;;
    esac
  done
  [[ "$ROLLOUT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a number of seconds."
  if [[ $ALL -eq 1 && ${#DEPLOYMENTS[@]} -gt 0 ]]; then die "Use either -d or --all, not both."; fi
}

main() {
  parse_args "$@"
  case "${COMMAND:-menu}" in
    session)   cmd_session ;;
    status)    cmd_status ;;
    set-image) cmd_set_image ;;
    restart)   cmd_restart ;;
    menu)      cmd_menu ;;
    help)      usage ;;
    *) die "Unknown command '$COMMAND'. See --help." ;;
  esac
}

main "$@"
