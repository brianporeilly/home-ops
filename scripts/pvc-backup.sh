#!/usr/bin/env bash
# Ad hoc PVC backup: scale a Deployment to 0, mount its PVC read-only in a
# throwaway pod, tar the contents out to a local file, delete the throwaway
# pod, then scale the Deployment back to its original replica count.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: pvc-backup.sh -n NAMESPACE -d DEPLOYMENT [-p PVC_NAME] [-o OUTPUT_DIR] [-k CONTEXT] [-y]

  -n  Namespace (required)
  -d  Deployment name (required)
  -p  PVC claim name (optional; auto-detected if the Deployment mounts exactly one PVC)
  -o  Output directory for the tarball (default: ./backups)
  -k  kubectl context to use (default: current context)
  -y  Skip the confirmation prompt

Example:
  ./pvc-backup.sh -n vaultwarden -d vaultwarden -o ~/backups/old-cluster
EOF
}

NAMESPACE=""
DEPLOYMENT=""
PVC=""
OUTDIR="./backups"
CONTEXT=""
ASSUME_YES=0

while getopts "n:d:p:o:k:yh" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    d) DEPLOYMENT="$OPTARG" ;;
    p) PVC="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    k) CONTEXT="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$NAMESPACE" || -z "$DEPLOYMENT" ]]; then
  usage
  exit 1
fi

KCTL=(kubectl)
[[ -n "$CONTEXT" ]] && KCTL=(kubectl --context "$CONTEXT")

"${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null

if [[ -z "$PVC" ]]; then
  mapfile -t pvcs < <("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}' \
    | tr ' ' '\n' | grep -v '^$')
  if [[ ${#pvcs[@]} -eq 0 ]]; then
    echo "No PVC found on deployment/$DEPLOYMENT; pass one explicitly with -p" >&2
    exit 1
  elif [[ ${#pvcs[@]} -gt 1 ]]; then
    echo "Multiple PVCs found on deployment/$DEPLOYMENT (${pvcs[*]}); pass one with -p" >&2
    exit 1
  fi
  PVC="${pvcs[0]}"
fi

ORIG_REPLICAS=$("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')
[[ -z "$ORIG_REPLICAS" ]] && ORIG_REPLICAS=1

POD="pvc-backup-${DEPLOYMENT}-$$"

if [[ "$ASSUME_YES" != "1" ]]; then
  echo "About to scale deployment/$DEPLOYMENT (namespace $NAMESPACE${CONTEXT:+, context $CONTEXT}) to 0,"
  echo "back up PVC $PVC, then scale back to $ORIG_REPLICAS replica(s)."
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

CLEANED_UP=0
cleanup() {
  [[ "$CLEANED_UP" == "1" ]] && return
  CLEANED_UP=1
  echo "Cleaning up..."
  "${KCTL[@]}" -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "Scaling deployment/$DEPLOYMENT back to $ORIG_REPLICAS replica(s)..."
  "${KCTL[@]}" -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$ORIG_REPLICAS" >/dev/null
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTDIR"

echo "Scaling deployment/$DEPLOYMENT to 0 (was $ORIG_REPLICAS)..."
"${KCTL[@]}" -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas=0

echo "Waiting for pods to terminate..."
SELECTOR=$("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["spec"]["selector"]["matchLabels"]; print(",".join(f"{k}={v}" for k,v in d.items()))')
"${KCTL[@]}" -n "$NAMESPACE" wait --for=delete pod -l "$SELECTOR" --timeout=120s 2>/dev/null || true

echo "Starting backup pod (mounts PVC $PVC read-only)..."
cat <<EOF | "${KCTL[@]}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NAMESPACE
  labels:
    app: pvc-backup
spec:
  restartPolicy: Never
  containers:
    - name: backup
      image: alpine:3.20
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /backup
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC
        readOnly: true
EOF

echo "Waiting for backup pod to be ready..."
"${KCTL[@]}" -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=120s

TS=$(date +%Y%m%dT%H%M%S)
OUTFILE="$OUTDIR/${NAMESPACE}-${DEPLOYMENT}-${TS}.tar.gz"
echo "Streaming tar of $PVC to $OUTFILE..."
"${KCTL[@]}" -n "$NAMESPACE" exec "$POD" -- tar czf - -C /backup . > "$OUTFILE"

echo "Backup written to $OUTFILE ($(du -h "$OUTFILE" | cut -f1))"
