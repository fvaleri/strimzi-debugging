## Monitoring Kafka Metrics

Begin by using [session 001](/sessions/001) to deploy a Kafka cluster on Kubernetes.

> [!IMPORTANT]
> The NGINX ingress controller must be configured with SSL passthrough enabled.

Once the cluster is ready, install Prometheus, Grafana, and the Strimzi dashboards.

```sh
$ for f in sessions/002/install/*.yaml; do
  echo ">>> Installing $f"
  envsubst < "$f" | kubectl replace --force -f -
  sleep 5
done
>>> Installing sessions/002/install/010-prometheus-operator.yaml
namespace/prometheus created
customresourcedefinition.apiextensions.k8s.io/alertmanagers.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/podmonitors.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/prometheuses.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/prometheusrules.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/servicemonitors.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/thanosrulers.monitoring.coreos.com created
serviceaccount/prometheus-operator created
clusterrole.rbac.authorization.k8s.io/prometheus-operator created
clusterrolebinding.rbac.authorization.k8s.io/prometheus-operator created
service/prometheus-operator created
deployment.apps/prometheus-operator created
>>> Installing sessions/002/install/011-prometheus-server.yaml
serviceaccount/prometheus created
clusterrole.rbac.authorization.k8s.io/prometheus created
clusterrolebinding.rbac.authorization.k8s.io/prometheus created
service/prometheus created
ingress.networking.k8s.io/prometheus created
prometheus.monitoring.coreos.com/prometheus created
secret/additional-scrape-configs created
alertmanager.monitoring.coreos.com/alertmanager created
service/alertmanager created
ingress.networking.k8s.io/alertmanager created
secret/alertmanager-alertmanager created
>>> Installing sessions/002/install/012-prometheus-strimzi.yaml
podmonitor.monitoring.coreos.com/strimzi-cluster-operator-metrics-test created
podmonitor.monitoring.coreos.com/strimzi-entity-operator-metrics-test created
podmonitor.monitoring.coreos.com/strimzi-bridge-metrics-test created
podmonitor.monitoring.coreos.com/strimzi-kafka-and-cruise-control-metrics-test created
>>> Installing sessions/002/install/020-grafana-operator.yaml
namespace/grafana created
customresourcedefinition.apiextensions.k8s.io/grafanadashboards.integreatly.org created
customresourcedefinition.apiextensions.k8s.io/grafanadatasources.integreatly.org created
customresourcedefinition.apiextensions.k8s.io/grafananotificationchannels.integreatly.org created
customresourcedefinition.apiextensions.k8s.io/grafanas.integreatly.org created
serviceaccount/controller-manager created
role.rbac.authorization.k8s.io/leader-election-role created
clusterrole.rbac.authorization.k8s.io/manager-role created
clusterrole.rbac.authorization.k8s.io/metrics-reader created
clusterrole.rbac.authorization.k8s.io/proxy-role created
rolebinding.rbac.authorization.k8s.io/leader-election-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/manager-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/proxy-rolebinding created
service/controller-manager-metrics-service created
configmap/manager-config created
deployment.apps/controller-manager created
>>> Installing sessions/002/install/021-grafana-server.yaml
grafana.integreatly.org/grafana created
service/grafana created
ingress.networking.k8s.io/grafana created
grafanadatasource.integreatly.org/prometheus created
>>> Installing sessions/002/install/022-grafana-strimzi.yaml
grafanadashboard.integreatly.org/strimzi-operators created
grafanadashboard.integreatly.org/strimzi-kafka created
```

Once the Grafana pod is ready, access the dashboards at [http://grafana.f12i.io](http://grafana.f12i.io).

> [!NOTE]
> If Ingress resources are not supported in your environment, use port forwarding to access Grafana at http://localhost:8000:
> ```shell
> kubectl -n grafana port-forward service/grafana 8000:80
> ```

This configuration includes the Cluster Operator and Kafka dashboards by default.
You can easily [add additional dashboards](/sessions/002/install/032-grafana-strimzi.yaml) as needed.

You can also create alerting rules to receive notifications about specific metric conditions.
Alert management is handled by Prometheus Alert Manager, though this is beyond the scope of this session.
