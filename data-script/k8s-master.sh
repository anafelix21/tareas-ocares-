#!/bin/bash
# k8s-master: K3s control plane + kube-state-metrics + app (3 nodos dedicados) + scripts de fallas
# Lo descarga y ejecuta el user data de la plantilla lab-kafka-k8s.yaml
# Variables que recibe: DOCKER_USER (opcional)
exec > >(tee -a /var/log/lab.log) 2>&1
log() { echo "[$(date +%H:%M:%S)] [LAB] $*"; }
DOCKER_USER=${DOCKER_USER:-anafelixmendoza21}
NS=agropacayales-namespace
L=/home/ubuntu/lab
log "Instalando K3s (control plane)"
curl -sfL https://get.k3s.io | K3S_TOKEN=lab-kafka-k8s-2026 sh -s - server \
  --write-kubeconfig-mode 644 --node-name k8s-master --disable traefik,servicelb,metrics-server,local-storage
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes >/dev/null 2>&1; do sleep 2; done

# kubectl del usuario ubuntu: namespace del proyecto por defecto (no hace falta -n)
mkdir -p $L /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
KUBECONFIG=/home/ubuntu/.kube/config kubectl config set-context --current --namespace=$NS
echo 'export KUBECONFIG=$HOME/.kube/config' > /etc/profile.d/lab-kube.sh

# ---------- Namespace, configuracion, metricas del Backend 2 y Services
cat > $L/app.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: agropacayales-namespace}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: app-config, namespace: agropacayales-namespace}
data:
  SPRING_PROFILES_ACTIVE: "cloud"
  SERVER_PORT: "8081"
  SQL_HOST: "sqlserver-externo"
  SQL_SERVER: "sqlserver-externo"
  MONGO_URI: "mongodb://mongodb-externo:27017/agropacayales_db"
  MONGO_DATABASE: "agropacayales_db"
  ANALYTICS_URL: "http://backend-analitico:5000"
  ANALYTICS_EVENTS_ENABLED: "false"
  SECURITY_ENFORCE: "false"
  FLASK_ENV: "production"
  FLASK_DEBUG: "False"
---
apiVersion: v1
kind: ConfigMap
metadata: {name: backend2-metrics, namespace: agropacayales-namespace}
data:
  metrics_wsgi.py: |
    # Envuelve la app Flask del Backend 2 y publica /metrics con http_requests_total
    import threading
    from wsgi import app as flask_app

    _lock = threading.Lock()
    _contador = {}

    def _metricas():
        lineas = ["# HELP http_requests_total Peticiones HTTP atendidas por el Backend 2 Flask",
                  "# TYPE http_requests_total counter"]
        with _lock:
            for (metodo, ruta, estado), valor in sorted(_contador.items()):
                lineas.append('http_requests_total{method="%s",path="%s",status="%s"} %d'
                              % (metodo, ruta, estado, valor))
        return ("\n".join(lineas) + "\n").encode()

    def application(environ, start_response):
        ruta = environ.get("PATH_INFO", "/")
        if ruta == "/metrics":
            cuerpo = _metricas()
            start_response("200 OK", [("Content-Type", "text/plain; version=0.0.4"),
                                      ("Content-Length", str(len(cuerpo)))])
            return [cuerpo]
        estado = {"codigo": "500"}
        def _sr(status, headers, exc_info=None):
            estado["codigo"] = status.split(" ", 1)[0]
            return start_response(status, headers, exc_info)
        try:
            return flask_app(environ, _sr)
        finally:
            clave = (environ.get("REQUEST_METHOD", "GET"), ruta[:80].replace('"', ""), estado["codigo"])
            with _lock:
                _contador[clave] = _contador.get(clave, 0) + 1
---
apiVersion: v1
kind: Service
metadata: {name: frontend, namespace: agropacayales-namespace}
spec:
  type: NodePort
  selector: {app: frontend}
  ports: [{port: 80, targetPort: 80, nodePort: 30000}]
---
apiVersion: v1
kind: Service
metadata: {name: backend-transaccional, namespace: agropacayales-namespace}
spec:
  type: NodePort
  selector: {app: backend1}
  ports: [{port: 8081, targetPort: 8081, nodePort: 30001}]
---
apiVersion: v1
kind: Service
metadata: {name: backend-analitico, namespace: agropacayales-namespace}
spec:
  type: NodePort
  selector: {app: backend2}
  ports: [{port: 5000, targetPort: 5000, nodePort: 30002}]
---
apiVersion: v1
kind: Service
metadata: {name: kube-state-metrics-nodeport, namespace: kube-system}
spec:
  type: NodePort
  selector: {app.kubernetes.io/name: kube-state-metrics}
  ports: [{port: 8080, targetPort: 8080, nodePort: 30080}]
EOF

# ---------- Deployments (cada uno en su nodo dedicado). Este archivo restaura el estado sano.
cat > $L/deployments.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: frontend, namespace: agropacayales-namespace, labels: {app: frontend}}
spec:
  replicas: 1
  selector: {matchLabels: {app: frontend}}
  template:
    metadata: {labels: {app: frontend}}
    spec:
      nodeSelector: {role: frontend}
      enableServiceLinks: false
      containers:
      - name: frontend
        image: ${DOCKER_USER}/agropacayales-frontend:2.0
        ports: [{containerPort: 80}]
        resources: {requests: {cpu: 250m, memory: 128Mi}, limits: {memory: 256Mi}}
        readinessProbe: {httpGet: {path: /, port: 80}, initialDelaySeconds: 5, periodSeconds: 10}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend1, namespace: agropacayales-namespace, labels: {app: backend1}}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: backend1}}
  template:
    metadata: {labels: {app: backend1}}
    spec:
      nodeSelector: {role: backend1}
      enableServiceLinks: false
      containers:
      - name: backend1
        image: ${DOCKER_USER}/agropacayales-backend:2.0
        ports: [{containerPort: 8081}]
        envFrom: [{configMapRef: {name: app-config}}]
        resources: {requests: {cpu: 250m, memory: 512Mi}, limits: {memory: 1536Mi}}
        readinessProbe: {tcpSocket: {port: 8081}, initialDelaySeconds: 20, periodSeconds: 10}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend2, namespace: agropacayales-namespace, labels: {app: backend2}}
spec:
  replicas: 1
  selector: {matchLabels: {app: backend2}}
  template:
    metadata: {labels: {app: backend2}}
    spec:
      nodeSelector: {role: backend2}
      enableServiceLinks: false
      containers:
      - name: backend2
        image: ${DOCKER_USER}/agropacayales-backend-analitico:2.0
        command: ["gunicorn"]
        args: ["-w", "1", "--threads", "8", "-b", "0.0.0.0:5000", "--timeout", "60",
               "--access-logfile", "-", "--pythonpath", "/opt/metrics", "metrics_wsgi:application"]
        ports: [{containerPort: 5000}]
        envFrom: [{configMapRef: {name: app-config}}]
        volumeMounts: [{name: metrics, mountPath: /opt/metrics}]
        resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {memory: 1Gi}}
        readinessProbe: {tcpSocket: {port: 5000}, initialDelaySeconds: 15, periodSeconds: 10}
      volumes: [{name: metrics, configMap: {name: backend2-metrics}}]
EOF

kubectl apply -f $L/app.yaml
log "Instalando kube-state-metrics v2.13.0"
KSM=https://raw.githubusercontent.com/kubernetes/kube-state-metrics/v2.13.0/examples/standard
for f in service-account cluster-role cluster-role-binding deployment service; do
  until kubectl apply -f $KSM/$f.yaml; do sleep 3; done
done
kubectl apply -f $L/deployments.yaml

# ---------- Scripts de la FASE 6 (simulacion de fallas)
cat > /usr/local/bin/lab-oom <<'EOF'
#!/bin/bash
# Escenario 1: Backend 1 reserva 300 MiB de heap con un limite de 200 MiB -> OOMKilled
set -x
kubectl -n agropacayales-namespace patch deployment backend1 --type=json -p='[
 {"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"JAVA_TOOL_OPTIONS","value":"-Xms300m -Xmx300m -XX:+AlwaysPreTouch"}]},
 {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"128Mi"},
 {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"200Mi"}]'
EOF
cat > /usr/local/bin/lab-5xx <<'EOF'
#!/bin/bash
# Escenario 2: payloads invalidos (lista y texto en vez de objeto JSON) al Backend 2 -> HTTP 500
URL=http://localhost:30002/api/v1/analytics/eventos
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code} " -X POST $URL -H 'Content-Type: application/json' -d '[1,2,3]'
  curl -s -o /dev/null -w "%{http_code} " -X POST $URL -H 'Content-Type: application/json' -d '"payload-invalido"'
  sleep 1
done
echo
EOF
cat > /usr/local/bin/lab-pending <<'EOF'
#!/bin/bash
# Escenario 3: 20 replicas del frontend (250m CPU c/u) en un nodo de 2 vCPU -> Pending
set -x
kubectl -n agropacayales-namespace scale deployment frontend --replicas=20
EOF
cat > /usr/local/bin/lab-restaurar <<'EOF'
#!/bin/bash
# Deja los 3 deployments como al inicio (1 replica, memoria normal)
set -x
kubectl replace -f /home/ubuntu/lab/deployments.yaml
EOF
chmod +x /usr/local/bin/lab-*
chown -R ubuntu:ubuntu /home/ubuntu/lab /home/ubuntu/.kube

for d in frontend backend1 backend2; do kubectl -n $NS rollout status deploy/$d --timeout=20m; done
kubectl get nodes -L role
kubectl -n $NS get pods -o wide
log "CLUSTER LISTO: frontend 30000, backend1 30001, backend2 30002, kube-state-metrics 30080"
