#!/bin/bash
# EC2-Kafka: Kafka 3.7.1 + ZooKeeper + JMX Exporter 0.19.0 (puerto 7071)
# Lo descarga y ejecuta el user data de la plantilla lab-kafka-k8s.yaml
exec > >(tee -a /var/log/lab.log) 2>&1
log() { echo "[$(date +%H:%M:%S)] [LAB] $*"; }
export DEBIAN_FRONTEND=noninteractive
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99lab-lock
apt-get update -y && apt-get install -y openjdk-17-jdk-headless tmux netcat-openbsd curl
T=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/local-ipv4)
id kafka >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin kafka

log "Descargando Kafka 3.7.1 y JMX Exporter 0.19.0"
curl -fsSL https://archive.apache.org/dist/kafka/3.7.1/kafka_2.13-3.7.1.tgz -o /tmp/kafka.tgz
rm -rf /opt/kafka && mkdir -p /opt/kafka /opt/jmx
tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1
curl -fsSL https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/0.19.0/jmx_prometheus_javaagent-0.19.0.jar \
  -o /opt/jmx/jmx_prometheus_javaagent-0.19.0.jar

# Reglas JMX Exporter: MBeans de Kafka -> metricas Prometheus
cat > /opt/jmx/jmx_config.yaml <<'EOF'
lowercaseOutputName: true
lowercaseOutputLabelNames: true
rules:
  - pattern: "kafka.server<type=([^,]+), name=([^,]+)><>Count"
    name: kafka_server_$1_$2_count
    type: COUNTER
  - pattern: "kafka.server<type=([^,]+), name=([^,]+)><>Value"
    name: kafka_server_$1_$2
    type: GAUGE
  - pattern: "kafka.controller<type=([^,]+), name=([^,]+)><>Value"
    name: kafka_controller_$1_$2
    type: GAUGE
EOF

cat > /opt/kafka/config/server.properties <<EOF
broker.id=1
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://$PRIVATE_IP:9092
log.dirs=/var/lib/kafka-logs
zookeeper.connect=localhost:2181
num.partitions=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
auto.create.topics.enable=true
EOF
sed -i 's#^dataDir=.*#dataDir=/var/lib/zookeeper#' /opt/kafka/config/zookeeper.properties
mkdir -p /var/lib/kafka-logs /var/lib/zookeeper
chown -R kafka:kafka /opt/kafka /opt/jmx /var/lib/kafka-logs /var/lib/zookeeper

cat > /etc/systemd/system/zookeeper.service <<'EOF'
[Unit]
Description=Apache ZooKeeper
After=network.target
[Service]
User=kafka
ExecStart=/opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/kafka.service <<'EOF'
[Unit]
Description=Apache Kafka Broker + JMX Exporter (puerto 7071)
After=zookeeper.service
Requires=zookeeper.service
[Service]
User=kafka
Environment="KAFKA_HEAP_OPTS=-Xms1G -Xmx1G"
Environment="KAFKA_OPTS=-javaagent:/opt/jmx/jmx_prometheus_javaagent-0.19.0.jar=7071:/opt/jmx/jmx_config.yaml"
ExecStartPre=/bin/sleep 15
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now zookeeper kafka
echo 'export PATH=$PATH:/opt/kafka/bin' > /etc/profile.d/kafka.sh

# Ayudas para las capturas 7 y 12
cat > /usr/local/bin/kafka-demo <<'EOF'
#!/bin/bash
# Pantalla dividida: PRODUCTOR a la izquierda, CONSUMIDOR a la derecha
B=/opt/kafka/bin
tmux kill-session -t demo 2>/dev/null
tmux new-session -d -s demo "$B/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic eventos-negocio"
tmux split-window -h -t demo "$B/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic eventos-negocio --from-beginning"
tmux set -t demo pane-border-status top
tmux select-pane -t demo:0.1 -T CONSUMIDOR
tmux select-pane -t demo:0.0 -T PRODUCTOR
tmux attach -t demo
EOF
cat > /usr/local/bin/kafka-trafico <<'EOF'
#!/bin/bash
# ~2 minutos de trafico constante (2000 mensajes/s) para que el dashboard se mueva
/opt/kafka/bin/kafka-producer-perf-test.sh --topic eventos-negocio --num-records 240000 \
  --record-size 200 --throughput 2000 --producer-props bootstrap.servers=localhost:9092
EOF
chmod +x /usr/local/bin/kafka-demo /usr/local/bin/kafka-trafico

for p in 2181 9092 7071; do until nc -z -w 3 localhost $p; do log "Esperando puerto $p..."; sleep 10; done; done
log "KAFKA LISTO: broker 9092, ZooKeeper 2181, JMX Exporter 7071 (IP privada $PRIVATE_IP)"
