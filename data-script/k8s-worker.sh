#!/bin/bash
# Nodo worker K3s dedicado (frontend | backend1 | backend2)
# Lo descarga y ejecuta el user data de la plantilla lab-kafka-k8s.yaml
# Variables que recibe: MASTER_IP, ROLE
: "${MASTER_IP:?falta MASTER_IP}" "${ROLE:?falta ROLE (frontend|backend1|backend2)}"
exec > >(tee -a /var/log/lab.log) 2>&1
until timeout 3 bash -c "</dev/tcp/${MASTER_IP}/6443"; do echo "Esperando al master..."; sleep 10; done
curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_IP}:6443 K3S_TOKEN=lab-kafka-k8s-2026 \
  sh -s - agent --node-name k8s-node-${ROLE} --node-label role=${ROLE}
echo "[LAB] WORKER LISTO: k8s-node-${ROLE} (role=${ROLE})"
