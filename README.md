# Laboratorio: Kafka + Prometheus + Grafana + Fallas en Kubernetes (AWS EC2)

Despliegue completo en **AWS Academy Learner Lab** con **una sola plantilla de CloudFormation**: crea las 6 EC2 y sus grupos de seguridad, y cada instancia se instala sola.

⏱ **~7 minutos** de principio a fin: las 6 EC2 se lanzan **a la vez** (VPC propia con IPs privadas fijas, ninguna espera a otra) y cada una descarga e instala en paralelo.

| Archivo | Para qué |
| :-- | :-- |
| [`MANUAL_KAFKA_LAB.md`](MANUAL_KAFKA_LAB.md) | ✅ **Empieza aquí.** Paso a paso con las 18 capturas |
| [`lab-kafka-k8s.yaml`](lab-kafka-k8s.yaml) | Plantilla CloudFormation (se sube en la consola, no se edita) |
| [`data-script/`](data-script/) | Scripts completos de cada EC2. El user data de la plantilla solo los descarga y ejecuta (AWS limita el user data a 16 KB) |

| EC2 | Qué corre |
| :-- | :-- |
| `EC2-Kafka` | Kafka 3.7.1 + ZooKeeper + JMX Exporter 0.19.0 (7071) |
| `EC2-Monitoreo` | Prometheus (9090) + Grafana (3000) en Docker |
| `k8s-master` | K3s + kube-state-metrics + scripts `lab-oom`, `lab-5xx`, `lab-pending`, `lab-restaurar` |
| `k8s-node-frontend` / `k8s-node-backend1` / `k8s-node-backend2` | Frontend React, Backend 1 Spring Boot, Backend 2 Python + Flask |

> El repositorio debe seguir siendo **público**: las EC2 descargan los scripts desde `raw.githubusercontent.com`.
