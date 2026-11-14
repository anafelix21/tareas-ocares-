# Manual clic por clic — Kafka + Prometheus + Grafana + Fallas en Kubernetes (AWS EC2)

Todo se crea **solo** con **un archivo**: [`lab-kafka-k8s.yaml`](lab-kafka-k8s.yaml) (CloudFormation).
No hay que lanzar instancias una por una, copiar user data, cambiar nombres, IPs ni namespaces, y **no se usa el CMD de la PC**: las terminales se abren en el navegador con **EC2 Instance Connect**.

**Por qué el user data es tan corto:** AWS solo acepta 16 KB de user data por instancia. Por eso los scripts completos están en la carpeta [`data-script/`](data-script/) de este repo, y el user data de cada EC2 tiene solo 3 líneas: descarga su script desde GitHub y lo ejecuta pasándole las IPs privadas que CloudFormation ya conoce.

| Script | Lo ejecuta | Variables que recibe |
| :-- | :-- | :-- |
| [`data-script/kafka.sh`](data-script/kafka.sh) | `EC2-Kafka` | — |
| [`data-script/monitoreo.sh`](data-script/monitoreo.sh) | `EC2-Monitoreo` | `KAFKA_IP`, `MASTER_IP`, `BACKEND2_IP` |
| [`data-script/k8s-master.sh`](data-script/k8s-master.sh) | `k8s-master` | `DOCKER_USER` |
| [`data-script/k8s-worker.sh`](data-script/k8s-worker.sh) | los 3 nodos | `MASTER_IP`, `ROLE` (`frontend` / `backend1` / `backend2`) |

| EC2 (se crean solas) | Tipo | Qué instala su user data |
| :-- | :-- | :-- |
| `EC2-Kafka` | t3.medium | Kafka 3.7.1 + ZooKeeper + JMX Exporter 0.19.0 (puerto 7071) |
| `EC2-Monitoreo` | t3.small | Docker: Prometheus (9090) + Grafana (3000) con dashboard y alertas listos |
| `k8s-master` | t3.medium | K3s control plane + kube-state-metrics + despliegue de la app + scripts de fallas |
| `k8s-node-frontend` | t3.small | Nodo dedicado Frontend React (NodePort 30000) |
| `k8s-node-backend1` | t3.medium | Nodo dedicado Backend 1 Spring Boot (NodePort 30001) |
| `k8s-node-backend2` | t3.small | Nodo dedicado Backend 2 Python + Flask (NodePort 30002, publica `/metrics`) |

```
                    ┌──────────── EC2-Monitoreo ────────────┐
 Navegador ───────► │ Grafana :3000 ──► Prometheus :9090    │
                    └───────────────────────┬───────────────┘
                     scrape (IP privada)    │
          ┌─────────────────────────────────┼──────────────────────────────┐
          ▼                                 ▼                              ▼
 EC2-Kafka :7071 (JMX)        k8s-master :30080 (kube-state-metrics)   k8s-node-backend2 :30002/metrics
 Kafka :9092 · ZooKeeper :2181       │
                                     ├── k8s-node-frontend  → pod frontend  (app=frontend)
                                     ├── k8s-node-backend1  → pod backend1  (app=backend1)
                                     └── k8s-node-backend2  → pod backend2  (app=backend2)
```

> Namespace del proyecto: `agropacayales-namespace`. En `k8s-master` ya queda **por defecto**, así que todos los `kubectl` de este manual van **sin `-n`**.
> La FASE 6 excluye bases de datos externas: los backends arrancan sin MongoDB/SQL Server (no se necesitan para simular las fallas).

---

## 0. Learner Lab ⏱ min 0

- [ ] **Start Lab** → esperar el círculo verde → clic **AWS**
- [ ] Arriba a la derecha: **United States (N. Virginia)** (`us-east-1`)

---

## 1. Crear TODO con CloudFormation ⏱ min 1

**Buscar "CloudFormation" → Create stack → With new resources (standard)**

- [ ] Prepare template: **Choose an existing template**
- [ ] Template source: **Upload a template file** → **Choose file** → `lab-kafka-k8s.yaml` → **Next**
- [ ] Stack name: `lab`
- [ ] Parámetros: **no tocar nada** (`KeyName = vockey`, `ScriptsUrl` = carpeta `data-script` de GitHub, `DockerUser = anafelixmendoza21`) → **Next**
- [ ] Página *Configure stack options*: no tocar → **Next**
- [ ] **Submit**

Esperar **CREATE_COMPLETE** (~3 min). Luego el software sigue instalándose solo dentro de las EC2 **10–12 min más**.

> Pestaña **Outputs** del stack: quedan los links de Grafana, Prometheus, Frontend, etc. y la **IP privada de Kafka** (para comparar en la captura 8).

### Cómo abrir una terminal (sin CMD, en el navegador)

**EC2 → Instances →** marcar la instancia → **Connect** → pestaña **EC2 Instance Connect** → Username `ubuntu` → **Connect**.

Para saber si una EC2 terminó de instalarse:

```bash
tail -f /var/log/lab.log
```

Esperar la línea **`KAFKA LISTO`** / **`MONITOREO LISTO`** / **`CLUSTER LISTO`** según la EC2. Salir con **Ctrl+C**.

---

# FASE 1 — Infraestructura

## 2. Captura 1: instancias EC2 activas ⏱ min 5

**EC2 → Instances.** Las 6 deben estar en **Running** (Status check 2/2 tarda ~2 min más).

Si no se ve la columna *Private IPv4 address*: ícono ⚙️ (Preferences) arriba a la derecha de la tabla → activar **Private IPv4 address** → Confirm.

> 📸 **CAPTURA 1 — Instancias EC2 activas:** lista con `EC2-Kafka`, `EC2-Monitoreo`, `k8s-master` y los 3 nodos en **Running**, mostrando **Public IPv4** y **Private IPv4**.

## 3. Captura 2: grupo de seguridad de Kafka

**EC2 → Security Groups →** `lab-sg-kafka` → pestaña **Inbound rules**.

| Puerto | Origen | Para qué |
| :-- | :-- | :-- |
| 22 | 0.0.0.0/0 | SSH / Instance Connect |
| 9092 | 0.0.0.0/0 | Kafka Broker |
| 7071 | `lab-sg-monitoreo` | JMX Exporter (solo lo puede leer Prometheus) |

> 📸 **CAPTURA 2 — Grupo de Seguridad de Kafka (EC2 1):** reglas 22, 9092 y 7071.

## 4. Captura 3: grupo de seguridad de Monitoreo

**Security Groups →** `lab-sg-monitoreo` → **Inbound rules**: 22, 9090 (Prometheus UI) y 3000 (Grafana UI), origen 0.0.0.0/0.

> 📸 **CAPTURA 3 — Grupo de Seguridad de Monitoreo (EC2 2):** reglas 22, 9090 y 3000.

(Existe un tercero, `lab-sg-k8s`, para el clúster: 22, NodePorts 30000-32767 y tráfico interno entre nodos.)

---

# FASE 2 — Kafka en EC2-Kafka

Abrir terminal en **EC2-Kafka** (Instance Connect) y esperar `KAFKA LISTO` en `tail -f /var/log/lab.log`.

## 5. Captura 4: agente JMX Exporter ⏱ min 13

```bash
cat /opt/jmx/jmx_config.yaml
systemctl show kafka -p Environment
```

Debe verse `KAFKA_OPTS=-javaagent:/opt/jmx/jmx_prometheus_javaagent-0.19.0.jar=7071:/opt/jmx/jmx_config.yaml`.

> 📸 **CAPTURA 4 — Configuración del Agente JMX Exporter:** salida de los dos comandos.

## 6. Captura 5: procesos Kafka y ZooKeeper

```bash
ps aux | grep -E "zookeeper|kafka" | grep -v grep | cut -c1-200
sudo jps -l
curl -s localhost:7071/metrics | grep messagesinpersec
```

- `ps aux`: un proceso con `QuorumPeerMain` (ZooKeeper) y otro con `kafka.Kafka` que lleva `-javaagent:...jmx_prometheus_javaagent-0.19.0.jar=7071`.
- `jps`: `org.apache.zookeeper.server.quorum.QuorumPeerMain` y `kafka.Kafka`.
- `curl`: el JMX Exporter respondiendo en 7071.

> 📸 **CAPTURA 5 — Procesos de Kafka y ZooKeeper en ejecución.**

---

# FASE 3 — Producer y Consumer

## 7. Captura 6: crear el tópico ⏱ min 16

```bash
kafka-topics.sh --create --topic eventos-negocio --bootstrap-server localhost:9092 --partitions 1 --replication-factor 1
```

Respuesta: **`Created topic eventos-negocio.`**

> 📸 **CAPTURA 6 — Creación del tópico de eventos.**
> Hacerla **antes** del paso 8 (si el tópico ya existe, sale `already exists`).

## 8. Captura 7: productor y consumidor en pantalla dividida

```bash
kafka-demo
```

Se abre la terminal partida en dos (tmux): **PRODUCTOR a la izquierda**, **CONSUMIDOR a la derecha**. El cursor ya está en el productor; escribir un mensaje por línea y **Enter**:

```
{"evento":"CREACION","entidad":"INSUMO","id":1}
{"evento":"TRANSACCION","monto":150.5}
{"evento":"COSECHA","kg":320}
```

Cada mensaje aparece **al instante** a la derecha.

> 📸 **CAPTURA 7 — Flujo de mensajes en tiempo real.**
> Salir: **Ctrl+C** (cierra el productor) y otra vez **Ctrl+C** (cierra el consumidor).

---

# FASE 4 — Prometheus y Grafana en EC2-Monitoreo

Abrir terminal en **EC2-Monitoreo** y esperar `MONITOREO LISTO` en `tail -f /var/log/lab.log`.

## 9. Captura 8: prometheus.yml ⏱ min 20

```bash
cat /opt/monitoreo/prometheus.yml
```

El job `kafka_metrics` → `targets: ['IP_PRIVADA_DE_EC2-Kafka:7071']` (comparar con la columna Private IPv4 de `EC2-Kafka` o con el Output `KafkaIpPrivada`). Los otros dos jobs son los del clúster (FASE 6).

> 📸 **CAPTURA 8 — Archivo prometheus.yml.**

## 10. Captura 9: contenedores Docker

```bash
sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
```

`prometheus` (0.0.0.0:9090) y `grafana` (0.0.0.0:3000) en **Up**.

> 📸 **CAPTURA 9 — Contenedores Docker activos.**

---

# FASE 5 — Integración y visualización

## 11. Captura 10: targets en Prometheus ⏱ min 22

Navegador: `http://IP_PUBLICA_EC2-Monitoreo:9090/targets` (está en los Outputs del stack).

**`kafka_metrics`** en **UP** (verde). También deben salir `kube_state_metrics` y `backend2_flask` en UP cuando el clúster termine (`CLUSTER LISTO`).

> 📸 **CAPTURA 10 — Estado de Targets en Prometheus.**

## 12. Captura 11: data source en Grafana

Navegador: `http://IP_PUBLICA_EC2-Monitoreo:3000`

- [ ] Usuario `admin` · contraseña `admin` → Grafana pide cambiarla: poner una nueva y anotarla (o **Skip**).
- [ ] Menú ☰ → **Connections → Data sources → Prometheus** (ya viene creado).
- [ ] Bajar hasta el final → botón **Test** (o **Save & test**).

Mensaje verde: **"Data source is working"**.

> 📸 **CAPTURA 11 — Data Source Prometheus en Grafana.**

## 13. Captura 12: dashboard operativo de Kafka

1. En la terminal de **EC2-Kafka** generar tráfico (~2 min, 2000 mensajes/s):

   ```bash
   kafka-trafico
   ```

2. En Grafana: ☰ → **Dashboards** → **Kafka - Operativo y Fallas Kubernetes** (ya viene creado, se refresca cada 10 s).

La fila **Kafka** muestra *Ingesta de mensajes*, *Bytes de red* (entrada/salida) y *Peticiones de producción* subiendo mientras corre `kafka-trafico`.

> 📸 **CAPTURA 12 — Dashboard Operativo de Kafka** con las gráficas reaccionando al tráfico.

---

# FASE 6 — Simulación de fallas en Kubernetes

Abrir terminal en **`k8s-master`** y esperar `CLUSTER LISTO` en `tail -f /var/log/lab.log`. Estado sano:

```bash
kubectl get nodes -L role
kubectl get pods -o wide
```

3 pods `frontend-…`, `backend1-…`, `backend2-…` en **Running**, cada uno en su nodo dedicado.

Scripts que dejó el user data (cada uno muestra los comandos `kubectl` que ejecuta):

| Script | Qué hace |
| :-- | :-- |
| `lab-oom` | Escenario 1: Backend 1 reserva 300 MiB de heap con límite de 200 MiB |
| `lab-5xx` | Escenario 2: envía 60 payloads inválidos al Backend 2 |
| `lab-pending` | Escenario 3: escala el frontend a 20 réplicas |
| `lab-restaurar` | Deja los 3 deployments sanos otra vez |

## 14. Escenario 1 — OOMKilled en Backend 1 (Spring Boot) ⏱ min 30

```bash
lab-oom
kubectl get pods -l app=backend1 -w
```

En ~20 s el pod pasa a **`OOMKilled`** y luego a **`CrashLoopBackOff`**, con la columna **RESTARTS** subiendo. Salir del `-w` con **Ctrl+C**. Para mostrar el motivo:

```bash
kubectl describe pod -l app=backend1 | grep -A4 "Last State"
```

`Reason: OOMKilled` · `Exit Code: 137`.

> 📸 **CAPTURA 13 — Pod en estado CrashLoopBackOff / OOMKilled:** `kubectl get pods -l app=backend1` (+ el `describe`).

Esperar **2–3 min** (que reinicie varias veces) y en Grafana mirar el panel **Escenario 1 - Reinicios Backend 1**. También vale **Explore** con:

```
kube_pod_container_status_restarts_total{container="backend1"}
```

> 📸 **CAPTURA 14 — Incremento de reinicios en Grafana:** la línea del pod `backend1-…` subiendo en escalera.

Restaurar antes de seguir:

```bash
lab-restaurar
```

## 15. Escenario 2 — HTTP 5xx en Backend 2 (Python + Flask) ⏱ min 38

```bash
lab-5xx
```

Envía `[1,2,3]` y `"payload-invalido"` (una lista y un texto donde la API espera un objeto JSON) a `POST /api/v1/analytics/eventos`. Imprime los códigos: **`500 500 500 …`**.

```bash
kubectl get pods -l app=backend2
kubectl logs NOMBRE_DEL_POD_BACKEND2 --tail=40
```

(Cambiar `NOMBRE_DEL_POD_BACKEND2` por el nombre `backend2-xxxxx` que salió arriba.)

Se ve `ERROR:AgroPacayalesAnalytics:Excepción no manejada: ... argument after ** must be a mapping`, el `Traceback` con `TypeError` y las líneas de acceso `"POST /api/v1/analytics/eventos HTTP/1.1" 500`.

> 📸 **CAPTURA 15 — Logs del pod con excepción HTTP 500.**

En Grafana, panel **Escenario 2 - Errores 5xx Backend 2**, o **Explore**:

```
http_requests_total{status=~"5.."}
```

El contador sube de 0 a 60. (Volver a ejecutar `lab-5xx` para que suba más.)

> 📸 **CAPTURA 16 — Tasa de errores 5xx en Grafana.**

> El Backend 2 publica `http_requests_total` en `:30002/metrics` mediante un envoltorio WSGI (ConfigMap `backend2-metrics`) que cuenta cada respuesta por método, ruta y código. La imagen Docker no se modifica.

## 16. Escenario 3 — Saturación del nodo por escalado masivo ⏱ min 44

```bash
lab-pending
kubectl get pods -l app=frontend
```

El nodo `k8s-node-frontend` tiene 2 vCPU y cada réplica pide 250m: entran ~7 y el resto queda en **`Pending`**.

```bash
kubectl get pods -l app=frontend --field-selector=status.phase=Pending
kubectl describe pod -l app=frontend | grep -A3 "Events" | tail -4
```

Evento: `0/4 nodes are available: 1 Insufficient cpu, 3 node(s) didn't match Pod's node affinity/selector`.

> 📸 **CAPTURA 17 — Pods atrapados en estado Pending.**

Esperar **~1 min** y abrir `http://IP_PUBLICA_EC2-Monitoreo:9090/alerts`: la alerta **`PodsPending`** pasa a **FIRING** (rojo). También sirve **Graph** con `kube_pod_status_phase{phase="Pending"}` o el panel **Escenario 3** de Grafana mostrando un valor mayor que 0.

> 📸 **CAPTURA 18 — Alerta de pods Pending en Prometheus.**

Restaurar:

```bash
lab-restaurar
```

> En `/alerts` también están `ReiniciosDeContenedor` (escenario 1) y `ErroresHTTP5xx` (escenario 2): sirven como captura extra.

---

## 17. Al terminar

- **Pausa (seguir otro día):** **Stop Lab**. Al volver, todo arranca solo (Kafka, Docker y K3s están como servicios). Las IP **públicas** cambian (ver Outputs o EC2); las privadas y `prometheus.yml` siguen igual.
- **Borrar todo:** **CloudFormation → stack `lab` → Delete**. Elimina las 6 EC2 y los 3 grupos de seguridad juntos.

---

## Problemas frecuentes

| Síntoma | Causa | Solución |
| :-- | :-- | :-- |
| `/var/log/lab.log` no existe y nada se instala | La EC2 no pudo descargar su script de GitHub | Ver **Actions → Monitor and troubleshoot → Get system log**; el repo debe ser **público** |
| Stack en `ROLLBACK_COMPLETE` con *already exists* | Ya hay grupos `lab-sg-*` de un intento anterior | Borrar el stack viejo, o crear el nuevo con otro nombre (p. ej. `lab2`) |
| Stack falla por *instance type* o *limit* | Hay otras EC2 encendidas del Learner Lab | Apagar/terminar las instancias viejas y volver a crear el stack |
| Instance Connect no conecta | La EC2 aún está arrancando | Esperar 2 min a *Status check 2/2* |
| `kafka-topics.sh: command not found` | La sesión se abrió antes de terminar el user data | Cerrar y abrir otra vez Instance Connect |
| `kafka_metrics` **DOWN** | Kafka aún arrancando | `tail -f /var/log/lab.log` en EC2-Kafka hasta `KAFKA LISTO` |
| `kube_state_metrics` / `backend2_flask` **DOWN** | El clúster aún descarga imágenes | Esperar `CLUSTER LISTO` en `k8s-master` |
| `kubectl get pods` no muestra nada | Se abrió la terminal antes de terminar | Cerrar y abrir otra vez Instance Connect |
| El dashboard de Kafka sale plano | No hay tráfico o el rango es corto | `kafka-trafico` en EC2-Kafka y rango **Last 15 minutes** |
| `lab-oom` no llega a OOMKilled | El pod todavía se está recreando | `kubectl get pods -l app=backend1 -w` y esperar 30 s |
| La alerta `PodsPending` sale *Pending* (amarillo) | Debe durar 30 s antes de pasar a FIRING | Esperar 1 min y recargar `/alerts` |
