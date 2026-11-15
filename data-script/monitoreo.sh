#!/bin/bash
# EC2-Monitoreo: Prometheus (9090) + Grafana (3000) con dashboard y alertas
# Lo descarga y ejecuta el user data de la plantilla lab-kafka-k8s.yaml
# Variables que recibe: KAFKA_IP, MASTER_IP, BACKEND2_IP
: "${KAFKA_IP:?falta KAFKA_IP}" "${MASTER_IP:?falta MASTER_IP}" "${BACKEND2_IP:?falta BACKEND2_IP}"
exec > >(tee -a /var/log/lab.log) 2>&1
log() { echo "[$(date +%H:%M:%S)] [LAB] $*"; }
export DEBIAN_FRONTEND=noninteractive
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99lab-lock
apt-get update -y && apt-get install -y --no-install-recommends docker.io
systemctl enable --now docker
# Bajar las 2 imagenes en paralelo mientras se escriben las configuraciones
docker pull -q prom/prometheus:v2.53.0 >/dev/null & P1=$!
docker pull -q grafana/grafana:9.5.2 >/dev/null & P2=$!
usermod -aG docker ubuntu
M=/opt/monitoreo
mkdir -p $M/grafana/provisioning/datasources $M/grafana/provisioning/dashboards $M/grafana/dashboards

# prometheus.yml: Kafka por IP PRIVADA:7071 + metricas del cluster Kubernetes
cat > $M/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alertas.yml

scrape_configs:
  - job_name: kafka_metrics
    static_configs:
      - targets: ['${KAFKA_IP}:7071']

  - job_name: kube_state_metrics
    static_configs:
      - targets: ['${MASTER_IP}:30080']

  - job_name: backend2_flask
    static_configs:
      - targets: ['${BACKEND2_IP}:30002']
EOF

cat > $M/alertas.yml <<'EOF'
groups:
  - name: fallas-kubernetes
    rules:
      - alert: PodsPending
        expr: sum(kube_pod_status_phase{phase="Pending"}) > 0
        for: 30s
        labels: {severity: warning}
        annotations:
          summary: "Hay {{ $value }} pods en estado Pending (recursos agotados en el nodo)"
      - alert: ReiniciosDeContenedor
        expr: increase(kube_pod_container_status_restarts_total[5m]) > 0
        labels: {severity: critical}
        annotations:
          summary: "El contenedor {{ $labels.container }} se esta reiniciando (OOMKilled/CrashLoopBackOff)"
      - alert: ErroresHTTP5xx
        expr: sum(increase(http_requests_total{status=~"5.."}[2m])) > 0
        labels: {severity: critical}
        annotations:
          summary: "El Backend 2 devolvio {{ $value }} respuestas 5xx en los ultimos 2 minutos"
EOF

cat > $M/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

cat > $M/grafana/provisioning/dashboards/lab.yml <<'EOF'
apiVersion: 1
providers:
  - name: lab
    type: file
    options: {path: /var/lib/grafana/dashboards}
EOF

cat > $M/grafana/dashboards/lab.json <<'EOF'
{"title": "Kafka - Operativo y Fallas Kubernetes", "uid": "lab-kafka-k8s", "schemaVersion": 37,
 "refresh": "10s", "time": {"from": "now-30m", "to": "now"},
 "panels": [
  {"type": "row", "title": "Kafka (EC2-Kafka :7071)", "gridPos": {"x": 0, "y": 0, "w": 24, "h": 1}},
  {"type": "timeseries", "title": "Ingesta de mensajes (mensajes/s)", "gridPos": {"x": 0, "y": 1, "w": 8, "h": 8},
   "datasource": {"type": "prometheus", "uid": "prometheus"},
   "targets": [{"refId": "A", "expr": "rate(kafka_server_brokertopicmetrics_messagesinpersec_count[1m])", "legendFormat": "mensajes/s"}]},
  {"type": "timeseries", "title": "Bytes de red (bytes/s)", "gridPos": {"x": 8, "y": 1, "w": 8, "h": 8},
   "datasource": {"type": "prometheus", "uid": "prometheus"}, "fieldConfig": {"defaults": {"unit": "Bps"}, "overrides": []},
   "targets": [{"refId": "A", "expr": "rate(kafka_server_brokertopicmetrics_bytesinpersec_count[1m])", "legendFormat": "entrada"},
               {"refId": "B", "expr": "rate(kafka_server_brokertopicmetrics_bytesoutpersec_count[1m])", "legendFormat": "salida"}]},
  {"type": "timeseries", "title": "Peticiones de produccion (req/s)", "gridPos": {"x": 16, "y": 1, "w": 8, "h": 8},
   "datasource": {"type": "prometheus", "uid": "prometheus"},
   "targets": [{"refId": "A", "expr": "rate(kafka_server_brokertopicmetrics_totalproducerequestspersec_count[1m])", "legendFormat": "produce/s"},
               {"refId": "B", "expr": "rate(kafka_server_brokertopicmetrics_totalfetchrequestspersec_count[1m])", "legendFormat": "fetch/s"}]},
  {"type": "row", "title": "Fallas en Kubernetes", "gridPos": {"x": 0, "y": 9, "w": 24, "h": 1}},
  {"type": "timeseries", "title": "Escenario 1 - Reinicios Backend 1 (kube_pod_container_status_restarts_total)", "gridPos": {"x": 0, "y": 10, "w": 8, "h": 9},
   "datasource": {"type": "prometheus", "uid": "prometheus"},
   "targets": [{"refId": "A", "expr": "kube_pod_container_status_restarts_total{namespace=\"agropacayales-namespace\"}", "legendFormat": "{{pod}}"}]},
  {"type": "timeseries", "title": "Escenario 2 - Errores 5xx Backend 2 (http_requests_total{status=~\"5..\"})", "gridPos": {"x": 8, "y": 10, "w": 8, "h": 9},
   "datasource": {"type": "prometheus", "uid": "prometheus"},
   "targets": [{"refId": "A", "expr": "sum by (status, path) (http_requests_total{status=~\"5..\"})", "legendFormat": "{{status}} {{path}}"}]},
  {"type": "timeseries", "title": "Escenario 3 - Pods Pending (kube_pod_status_phase{phase=\"Pending\"})", "gridPos": {"x": 16, "y": 10, "w": 8, "h": 9},
   "datasource": {"type": "prometheus", "uid": "prometheus"},
   "targets": [{"refId": "A", "expr": "sum(kube_pod_status_phase{phase=\"Pending\"})", "legendFormat": "pods Pending"}]}
 ]}
EOF
  $M/grafana/provisioning/dashboards/lab.yml $M/grafana/dashboards/lab.json
chmod -R a+rX $M

# Esperar SOLO los 2 pulls (un 'wait' sin PIDs tambien espera al tee del log y se cuelga)
wait $P1 $P2
docker rm -f prometheus grafana >/dev/null 2>&1
docker network create monitoreo 2>/dev/null || true
docker run -d --name prometheus --restart always --network monitoreo -p 9090:9090 \
  -v $M/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  -v $M/alertas.yml:/etc/prometheus/alertas.yml:ro \
  prom/prometheus:v2.53.0
docker run -d --name grafana --restart always --network monitoreo -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -v $M/grafana/provisioning:/etc/grafana/provisioning:ro \
  -v $M/grafana/dashboards:/var/lib/grafana/dashboards:ro \
  grafana/grafana:9.5.2
for p in 9090 3000; do until (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null; do sleep 2; done; done
log "MONITOREO LISTO: Prometheus 9090, Grafana 3000. Kafka target: ${KAFKA_IP}:7071"
