#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-lab8-spark}"
DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-kubernetes-dashboard}"
IMAGE_NAME="${IMAGE_NAME:-lab8-spark-model:latest}"
DATA_FILE="${DATA_FILE:-${ROOT_DIR}/src/data/food_small.parquet}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8443}"
SPARK_UI_PORT="${SPARK_UI_PORT:-4040}"
MONGO_EXPRESS_PORT="${MONGO_EXPRESS_PORT:-8081}"
RUN_SPARK_JOB="${RUN_SPARK_JOB:-0}"
RESET_K8S_RESOURCES="${RESET_K8S_RESOURCES:-1}"
RESET_DASHBOARD="${RESET_DASHBOARD:-1}"

PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "${pid}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

cd "${ROOT_DIR}"

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is not installed."
    exit 1
  }
}

is_port_free() {
  python3 - "$1" <<'PY'
import socket
import sys

port = int(sys.argv[1])
for host in ("127.0.0.1", "::1"):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        sock.bind((host, port))
    except OSError:
        sys.exit(1)
    finally:
        sock.close()
sys.exit(0)
PY
}

pick_port() {
  local preferred="$1"
  local label="$2"
  local port="${preferred}"

  for _ in $(seq 1 100); do
    if is_port_free "${port}"; then
      if [[ "${port}" != "${preferred}" ]]; then
        echo "Port ${preferred} for ${label} is busy, using ${port} instead." >&2
      fi
      echo "${port}"
      return 0
    fi
    port=$((port + 1))
  done

  echo "Could not find a free local port for ${label} starting from ${preferred}." >&2
  return 1
}

reset_k8s_resources() {
  if [[ "${RESET_K8S_RESOURCES}" != "1" ]]; then
    echo "Skipping Kubernetes resource cleanup because RESET_K8S_RESOURCES=${RESET_K8S_RESOURCES}."
    return 0
  fi

  echo "Cleaning previous lab resources in namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found

  for _ in $(seq 1 120); do
    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace ${NAMESPACE} is still terminating. Check finalizers with:"
    echo "  kubectl get namespace ${NAMESPACE} -o yaml"
    exit 1
  fi

  if [[ "${RESET_DASHBOARD}" == "1" ]]; then
    echo "Cleaning previous Kubernetes Dashboard resources..."
    kubectl delete namespace "${DASHBOARD_NAMESPACE}" --ignore-not-found
    for _ in $(seq 1 120); do
      if ! kubectl get namespace "${DASHBOARD_NAMESPACE}" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  fi
}

cleanup_stale_port_forwards() {
  echo "Stopping stale lab port-forwards if any..."
  pkill -f "kubectl.*port-forward.*lab8-spark" >/dev/null 2>&1 || true
  pkill -f "kubectl.*port-forward.*kubernetes-dashboard" >/dev/null 2>&1 || true
  pkill -f "kubectl.*port-forward.*model-service" >/dev/null 2>&1 || true
  pkill -f "kubectl.*port-forward.*mongo-express" >/dev/null 2>&1 || true
  pkill -f "kubectl.*port-forward.*kubernetes-dashboard-kong-proxy" >/dev/null 2>&1 || true
  sleep 1
}

start_port_forward() {
  local label="$1"
  local command="$2"
  local logfile="$3"

  echo "Starting port-forward for ${label}..."
  rm -f "${logfile}"
  bash -c "${command}" >"${logfile}" 2>&1 &
  local pid="$!"
  sleep 2

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    echo "Failed to start port-forward for ${label}."
    echo "Log:"
    cat "${logfile}" 2>/dev/null || true
    return 1
  fi

  PIDS+=("${pid}")
  return 0
}

get_ready_model_service_pod() {
  local pod_name=""

  for _ in $(seq 1 60); do
    pod_name="$(
      kubectl get pods -n "${NAMESPACE}" \
        -l app=model-service \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | head -n 1
    )"

    if [[ -n "${pod_name}" ]]; then
      if kubectl wait --for=condition=Ready "pod/${pod_name}" -n "${NAMESPACE}" --timeout=5s >/dev/null 2>&1; then
        echo "${pod_name}"
        return 0
      fi
    fi

    sleep 2
  done

  return 1
}

wait_and_start_spark_ui_forward() {
  local pod_name="$1"
  local logfile="$2"

  rm -f "${logfile}"
  echo "Waiting for Spark UI on model-service pod ${pod_name}..."

  for _ in $(seq 1 600); do
    if kubectl exec -n "${NAMESPACE}" "${pod_name}" -- python3 -c "import socket; s=socket.create_connection(('127.0.0.1', 4040), 1); s.close()" >/dev/null 2>&1; then
      echo "Spark UI is ready, starting port-forward..."
      kubectl port-forward -n "${NAMESPACE}" "pod/${pod_name}" "${SPARK_UI_PORT}:4040" >"${logfile}" 2>&1 &
      local pf_pid="$!"
      trap 'kill "${pf_pid}" >/dev/null 2>&1 || true' EXIT
      wait "${pf_pid}"
      return 0
    fi
    sleep 2
  done

  echo "Spark UI did not become ready. Run POST /predict in Swagger and check model-service logs."
  return 1
}

need_command kubectl
need_command docker
need_command minikube
need_command python3

if ! minikube status >/dev/null 2>&1; then
  echo "Starting minikube with Docker driver..."
  minikube start --driver=docker
fi

echo "Using minikube context..."
kubectl config use-context minikube >/dev/null

cleanup_stale_port_forwards
reset_k8s_resources

SERVICE_PORT="$(pick_port "${SERVICE_PORT}" "model service Swagger")"
DASHBOARD_PORT="$(pick_port "${DASHBOARD_PORT}" "Kubernetes Dashboard")"
SPARK_UI_PORT="$(pick_port "${SPARK_UI_PORT}" "Spark UI")"
MONGO_EXPRESS_PORT="$(pick_port "${MONGO_EXPRESS_PORT}" "Mongo Express")"

echo "Building ${IMAGE_NAME} inside minikube Docker daemon..."
eval "$(minikube docker-env)"
docker build -t "${IMAGE_NAME}" .

echo "Deploying model service manifests..."
kubectl apply -k k8s
kubectl delete -f k8s/spark-predict-job.yaml --ignore-not-found >/dev/null
kubectl delete pod -n "${NAMESPACE}" -l spark-role=driver --ignore-not-found >/dev/null
kubectl delete pod -n "${NAMESPACE}" -l spark-role=executor --ignore-not-found >/dev/null
kubectl delete svc -n "${NAMESPACE}" -l spark-role=driver --ignore-not-found >/dev/null
kubectl rollout status deployment/mongodb -n "${NAMESPACE}" --timeout=180s
kubectl rollout status deployment/mongo-express -n "${NAMESPACE}" --timeout=180s
kubectl rollout restart deployment/model-service -n "${NAMESPACE}"
kubectl rollout status deployment/model-service -n "${NAMESPACE}" --timeout=180s

if [[ -f "${DATA_FILE}" ]]; then
  echo "Uploading data file to PVC: ${DATA_FILE}"
  kubectl delete -f k8s/data-loader-pod.yaml --ignore-not-found >/dev/null
  kubectl apply -f k8s/data-loader-pod.yaml
  kubectl wait --for=condition=Ready pod/data-loader -n "${NAMESPACE}" --timeout=120s
  kubectl exec -n "${NAMESPACE}" data-loader -- sh -c "mkdir -p /opt/app/shared/data /opt/app/shared/artifacts && chown -R 185:0 /opt/app/shared && chmod -R g+rwX /opt/app/shared"
  kubectl cp "${DATA_FILE}" "${NAMESPACE}/data-loader:/opt/app/shared/data/food_small.parquet"
else
  echo "Data file was not found: ${DATA_FILE}"
  echo "Swagger and /health will work, but /predict needs this parquet file."
fi

DASHBOARD_TOKEN=""
if command -v helm >/dev/null 2>&1; then
  echo "Installing Kubernetes Dashboard..."
  helm repo add kubernetes-dashboard https://kubernetes-retired.github.io/dashboard/ >/dev/null
  helm repo update kubernetes-dashboard >/dev/null
  helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --create-namespace \
    --namespace "${DASHBOARD_NAMESPACE}"

  kubectl apply -f k8s/dashboard-admin.yaml
  kubectl rollout status deployment/kubernetes-dashboard-kong -n "${DASHBOARD_NAMESPACE}" --timeout=300s
  kubectl rollout status deployment/kubernetes-dashboard-web -n "${DASHBOARD_NAMESPACE}" --timeout=300s

  DASHBOARD_TOKEN="$(kubectl -n "${DASHBOARD_NAMESPACE}" create token admin-user)"
  cat <<EOF

Kubernetes Dashboard token:
${DASHBOARD_TOKEN}
EOF
else
  echo "helm is not installed, skipping Kubernetes Dashboard installation."
  echo "Install it with: brew install helm"
fi

if [[ "${RUN_SPARK_JOB}" == "1" ]]; then
  echo "Starting Spark Kubernetes job for Spark UI..."
  kubectl delete -f k8s/spark-predict-job.yaml --ignore-not-found >/dev/null
  kubectl apply -f k8s/spark-predict-job.yaml
fi

MODEL_SERVICE_POD="$(get_ready_model_service_pod)" || {
  echo "Could not find a Ready model-service pod."
  kubectl get pods -n "${NAMESPACE}" -l app=model-service
  exit 1
}

start_port_forward \
  "model service Swagger pod ${MODEL_SERVICE_POD}" \
  "kubectl port-forward -n ${NAMESPACE} pod/${MODEL_SERVICE_POD} ${SERVICE_PORT}:8000" \
  "/tmp/lab8-model-service-port-forward.log"

start_port_forward \
  "Mongo Express" \
  "kubectl port-forward -n ${NAMESPACE} svc/mongo-express ${MONGO_EXPRESS_PORT}:8081" \
  "/tmp/lab8-mongo-express-port-forward.log"

if [[ -n "${DASHBOARD_TOKEN}" ]]; then
  start_port_forward \
    "Kubernetes Dashboard" \
    "kubectl -n ${DASHBOARD_NAMESPACE} port-forward svc/kubernetes-dashboard-kong-proxy ${DASHBOARD_PORT}:443" \
    "/tmp/lab8-kubernetes-dashboard-port-forward.log"
fi

SPARK_DRIVER_POD="${MODEL_SERVICE_POD}"
wait_and_start_spark_ui_forward "${MODEL_SERVICE_POD}" "/tmp/lab8-spark-ui-port-forward.log" &
PIDS+=("$!")

if [[ "${RUN_SPARK_JOB}" == "1" ]]; then
  echo "Waiting for a running Spark driver pod..."
  BATCH_SPARK_DRIVER_POD=""
  for _ in $(seq 1 45); do
    BATCH_SPARK_DRIVER_POD="$(
      kubectl get pods -n "${NAMESPACE}" \
        -l spark-role=driver \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"
    if [[ -n "${BATCH_SPARK_DRIVER_POD}" ]]; then
      break
    fi
    sleep 2
  done

  if [[ -n "${BATCH_SPARK_DRIVER_POD}" ]]; then
    echo "Batch Spark driver pod is running: ${BATCH_SPARK_DRIVER_POD}"
  else
    echo "Batch Spark driver pod was not found. The job may have failed or finished too quickly."
  fi
fi

cat <<EOF

============================================================
Lab 8 Kubernetes environment is running.
Keep this terminal open; port-forwards stop when it exits.
============================================================

Model service:
  Health:  http://localhost:${SERVICE_PORT}/health
  Swagger: http://localhost:${SERVICE_PORT}/docs
  Predict:
    curl -X POST http://localhost:${SERVICE_PORT}/predict -H "Content-Type: application/json" -d '{}'

Kubernetes:
  kubectl get pods -n ${NAMESPACE}
  kubectl get deployment,svc,pvc -n ${NAMESPACE}

MongoDB:
  Mongo Express: http://localhost:${MONGO_EXPRESS_PORT}
  Login: admin / admin
EOF

if [[ -n "${DASHBOARD_TOKEN}" ]]; then
  cat <<EOF

Kubernetes Dashboard:
  URL: https://localhost:${DASHBOARD_PORT}
  Browser may show a self-signed certificate warning; accept it for local minikube.
  Token:
${DASHBOARD_TOKEN}
EOF
else
  cat <<EOF

Kubernetes Dashboard:
  Not started because Helm is missing.
  Install Helm: brew install helm
  Then rerun this script.
EOF
fi

if [[ -n "${SPARK_DRIVER_POD}" ]]; then
  cat <<EOF

Spark UI:
  URL: http://localhost:${SPARK_UI_PORT}
  Model service pod: ${SPARK_DRIVER_POD}

Note: open Swagger and run POST /predict first.
The script watches the selected model-service pod and opens Spark UI forwarding when port 4040 appears.
EOF
else
  cat <<EOF

Spark UI:
  Not available right now.
  Spark UI exists only while a Spark driver pod is Running.
EOF
fi

cat <<EOF

Logs:
  Model service: kubectl logs -n ${NAMESPACE} deploy/model-service --tail=120
  Spark job:     kubectl logs -n ${NAMESPACE} job/spark-model-predict

Press Ctrl+C to stop port-forwards.
EOF

while true; do
  sleep 60
done
