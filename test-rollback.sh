#!/usr/bin/env bash
# =============================================================================
# test-rollback.sh
# Runs the full ArgoCD automatic rollback test scenario.
#
# Prerequisites:
#   - minikube running
#   - ArgoCD installed in 'argocd' namespace
#   - Images built via build-and-load.sh
#   - ArgoCD Application 'three-tier-app' already applied and Synced
#   - GITOPS_REPO_DIR env var pointing to your local 3tier-gitops clone
#
# Usage:
#   export GITOPS_REPO_DIR=/path/to/3tier-gitops
#   export ARGOCD_PASSWORD=<admin-password>
#   bash test-rollback.sh
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}══ STEP $1 ══${NC} $2"; }
log()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[✓]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[✗]${NC}    $*"; }
pause() { echo -e "${YELLOW}[PAUSE]${NC} $*"; sleep "${1:-3}"; }

GITOPS_DIR="${GITOPS_REPO_DIR:-../3tier-gitops}"
BACKEND_DEPLOY="$GITOPS_DIR/k8s/backend/deployment.yaml"
APP_NAME="three-tier-app"
NAMESPACE="three-tier"
ARGOCD_SERVER="${ARGOCD_SERVER:-localhost:8080}"
ARGOCD_USER="${ARGOCD_USER:-admin}"
ARGOCD_PASS="${ARGOCD_PASSWORD:-}"

# ─────────────────────────────────────────────────────────────────────────────
step 0 "Pre-flight checks"
# ─────────────────────────────────────────────────────────────────────────────
for cmd in kubectl argocd git; do
  if ! command -v $cmd &>/dev/null; then
    fail "'$cmd' not found. Please install it."; exit 1
  fi
done

if [ ! -f "$BACKEND_DEPLOY" ]; then
  fail "Cannot find $BACKEND_DEPLOY"
  fail "Set GITOPS_REPO_DIR to your local 3tier-gitops clone path."
  exit 1
fi
ok "All tools found"
ok "GitOps dir: $GITOPS_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step 1 "Verify v1 is deployed and healthy"
# ─────────────────────────────────────────────────────────────────────────────
log "Waiting for all pods to be Running..."
kubectl wait deployment/backend \
  -n $NAMESPACE \
  --for=condition=Available \
  --timeout=120s
ok "Backend deployment is Available"

CURRENT_IMAGE=$(kubectl get deployment backend -n $NAMESPACE \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
log "Current image: $CURRENT_IMAGE"

# ─────────────────────────────────────────────────────────────────────────────
step 2 "Log in to ArgoCD"
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$ARGOCD_PASS" ]; then
  warn "ARGOCD_PASSWORD not set. Trying to read from secret..."
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
fi

argocd login "$ARGOCD_SERVER" \
  --username "$ARGOCD_USER" \
  --password "$ARGOCD_PASS" \
  --insecure \
  --grpc-web

ok "Logged in to ArgoCD at $ARGOCD_SERVER"

log "Current app status:"
argocd app get $APP_NAME --refresh

# ─────────────────────────────────────────────────────────────────────────────
step 3 "Inject BROKEN image tag into GitOps repo"
# ─────────────────────────────────────────────────────────────────────────────
warn "This will commit 'three-tier-backend:v2-broken' to your GitOps repo!"
warn "This tag does NOT exist → will trigger ImagePullBackOff"
pause 3

# Patch the deployment.yaml
sed -i 's|image: three-tier-backend:v1|image: three-tier-backend:v2-broken|g' "$BACKEND_DEPLOY"
# Also update the APP_VERSION env var
sed -i 's|value: "v1"|value: "v2-broken"|g' "$BACKEND_DEPLOY"

ok "Patched $BACKEND_DEPLOY → three-tier-backend:v2-broken"

# Commit and push
cd "$GITOPS_DIR"
git add k8s/backend/deployment.yaml
git commit -m "chore: deploy v2-broken to test ArgoCD rollback [$(date -u +%Y-%m-%dT%H:%M:%SZ)]"
git push origin main
ok "Pushed broken commit to GitOps repo"

cd - >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
step 4 "Watch ArgoCD detect the broken deploy"
# ─────────────────────────────────────────────────────────────────────────────
log "ArgoCD polls the repo every 3 minutes by default."
log "Forcing a sync now to speed up the demo..."
argocd app sync $APP_NAME

log "Watching pod status (waiting for ImagePullBackOff)..."
echo ""
echo -e "${YELLOW}Live pod status — press Ctrl+C when you see ErrImagePull/ImagePullBackOff:${NC}"
echo "--------------------------------------------------------------------"
kubectl get pods -n $NAMESPACE -w &
WATCH_PID=$!

# Wait for ImagePullBackOff
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  STATUS=$(kubectl get pods -n $NAMESPACE \
    -l app=backend \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "$STATUS" == *"ImagePull"* ]] || [[ "$STATUS" == *"ErrImage"* ]]; then
    ok "Detected: Backend pod is in '$STATUS' state!"
    break
  fi
  sleep 3
  WAITED=$((WAITED + 3))
done
kill $WATCH_PID 2>/dev/null || true

log "ArgoCD app health status:"
argocd app get $APP_NAME | grep -E "Health Status|Sync Status" || true

# ─────────────────────────────────────────────────────────────────────────────
step 5 "Trigger ArgoCD rollback to previous revision"
# ─────────────────────────────────────────────────────────────────────────────
log "Rolling back to the last known-good revision..."

# Get previous revision number
PREV_REVISION=$(argocd app history $APP_NAME --output json 2>/dev/null | \
  python3 -c "import json,sys; h=json.load(sys.stdin); print(h[-2]['revision'] if len(h)>=2 else 'HEAD~1')" 2>/dev/null || echo "")

if [ -n "$PREV_REVISION" ]; then
  log "Rolling back to revision: $PREV_REVISION"
  argocd app rollback $APP_NAME $PREV_REVISION
else
  warn "Could not determine previous revision. Rolling back to HEAD~1..."
  argocd app rollback $APP_NAME
fi

ok "Rollback command issued!"

# ─────────────────────────────────────────────────────────────────────────────
step 6 "Wait for healthy state"
# ─────────────────────────────────────────────────────────────────────────────
log "Waiting for backend to become Available again..."
kubectl rollout status deployment/backend -n $NAMESPACE --timeout=120s

ok "Backend deployment is healthy again!"

log "Final pod status:"
kubectl get pods -n $NAMESPACE

log "Final ArgoCD app status:"
argocd app get $APP_NAME

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  ✅ ROLLBACK TEST COMPLETE                        ║${NC}"
echo -e "${GREEN}${BOLD}║                                                  ║${NC}"
echo -e "${GREEN}${BOLD}║  v1 has been restored successfully!               ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
step 7 "Optional — restore GitOps repo to v1 state"
# ─────────────────────────────────────────────────────────────────────────────
warn "The GitOps repo still has v2-broken committed."
warn "Run these commands to revert it:"
echo ""
echo "  cd $GITOPS_DIR"
echo "  git revert HEAD --no-edit"
echo "  git push origin main"
echo ""
echo "  # Then re-enable ArgoCD auto-sync (rollback disables it):"
echo "  argocd app set $APP_NAME --sync-policy automated"
echo ""
