# 3-Tier GitOps — ArgoCD Rollback Demo

ArgoCD source-of-truth repository for the 3-tier app rollback demo.

## Structure

```
3tier-gitops/
├── argocd/
│   └── application.yaml       ← ArgoCD App definition (apply this once)
├── k8s/
│   ├── namespace.yaml
│   ├── frontend/
│   │   ├── deployment.yaml    ← three-tier-frontend:v1
│   │   └── service.yaml       ← NodePort :30080
│   ├── backend/
│   │   ├── deployment.yaml    ← three-tier-backend:v1  ← change tag here to break!
│   │   └── service.yaml       ← ClusterIP :3000
│   └── database/
│       ├── deployment.yaml    ← postgres:15-alpine
│       ├── service.yaml       ← ClusterIP :5432
│       ├── secret.yaml        ← credentials
│       └── pvc.yaml           ← 1Gi storage
└── test-rollback.sh           ← Automated rollback test script
```

## Setup

### 1. Replace the repoURL

Edit `argocd/application.yaml` and set your GitOps repo URL:
```yaml
source:
  repoURL: https://github.com/YOUR_USERNAME/3tier-gitops.git
```

### 2. Push to GitHub
```bash
git init
git add .
git commit -m "feat: initial 3-tier app manifests"
git remote add origin https://github.com/YOUR_USERNAME/3tier-gitops.git
git push -u origin main
```

### 3. Add repo to ArgoCD (if private)
```bash
argocd repo add https://github.com/YOUR_USERNAME/3tier-gitops.git \
  --username YOUR_GITHUB_USER \
  --password YOUR_PAT_TOKEN
```

### 4. Apply the Application
```bash
kubectl apply -f argocd/application.yaml
```

### 5. Watch it sync
```bash
argocd app get three-tier-app
argocd app sync three-tier-app   # Force first sync
kubectl get pods -n three-tier -w
```

---

## Rollback Test

### Option A — Self-Heal (no Git commit needed)
```bash
# Manually corrupt the deployment — ArgoCD will revert it automatically
kubectl patch deployment backend -n three-tier \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"backend","image":"three-tier-backend:v2-broken"}]}}}}'

# Watch ArgoCD self-heal (within ~30s)
kubectl get pods -n three-tier -w
argocd app get three-tier-app
```

### Option B — Bad Git commit → argocd rollback
```bash
# Run the full automated test script
export GITOPS_REPO_DIR=$(pwd)
bash test-rollback.sh
```

### Rollback a specific revision manually
```bash
argocd app history three-tier-app
argocd app rollback three-tier-app <REVISION_NUMBER>
```

### Re-enable auto-sync after rollback
```bash
argocd app set three-tier-app --sync-policy automated
```

---

## Key ArgoCD Config (application.yaml)

| Setting | Value | Effect |
|---------|-------|--------|
| `automated.selfHeal` | `true` | Revert manual K8s changes to Git state |
| `automated.prune` | `true` | Delete resources removed from Git |
| `syncOptions.CreateNamespace` | `true` | Auto-create `three-tier` namespace |
