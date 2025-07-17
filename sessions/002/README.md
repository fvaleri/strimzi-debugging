## Monitor Kafka metrics

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

When the cluster is ready, install Prometheus, Grafana and Strimzi dashboards.
Only the Cluster Operator and Kafka dashboards are included, but you can easily add the other components.

```sh
$ for f in sessions/002/install/*.yaml; do
  echo ">>> Installing $f"
  envsubst < "$f" | kubectl apply -f -
  sleep 5
done
>>> Installing sessions/002/install/010-metrics-server.yaml
serviceaccount/metrics-server unchanged
clusterrole.rbac.authorization.k8s.io/system:aggregated-metrics-reader unchanged
rolebinding.rbac.authorization.k8s.io/metrics-server-auth-reader unchanged
clusterrolebinding.rbac.authorization.k8s.io/metrics-server:system:auth-delegator unchanged
clusterrole.rbac.authorization.k8s.io/system:metrics-server unchanged
clusterrolebinding.rbac.authorization.k8s.io/system:metrics-server unchanged
service/metrics-server unchanged
deployment.apps/metrics-server configured
apiservice.apiregistration.k8s.io/v1beta1.metrics.k8s.io unchanged
>>> Installing sessions/002/install/020-prometheus-operator.yaml
namespace/prometheus created
customresourcedefinition.apiextensions.k8s.io/alertmanagers.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/podmonitors.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/prometheuses.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/prometheusrules.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/servicemonitors.monitoring.coreos.com created
customresourcedefinition.apiextensions.k8s.io/thanosrulers.monitoring.coreos.com created
serviceaccount/prometheus-operator created
clusterrole.rbac.authorization.k8s.io/prometheus-operator unchanged
clusterrolebinding.rbac.authorization.k8s.io/prometheus-operator unchanged
service/prometheus-operator created
deployment.apps/prometheus-operator created
>>> Installing sessions/002/install/021-prometheus-server.yaml
namespace/prometheus unchanged
serviceaccount/prometheus created
clusterrole.rbac.authorization.k8s.io/prometheus unchanged
clusterrolebinding.rbac.authorization.k8s.io/prometheus unchanged
service/prometheus created
ingress.networking.k8s.io/prometheus created
prometheus.monitoring.coreos.com/prometheus created
secret/additional-scrape-configs created
alertmanager.monitoring.coreos.com/alertmanager created
service/alertmanager created
ingress.networking.k8s.io/alertmanager created
secret/alertmanager-alertmanager created
>>> Installing sessions/002/install/022-prometheus-strimzi.yaml
podmonitor.monitoring.coreos.com/strimzi-cluster-operator-metrics-test created
podmonitor.monitoring.coreos.com/strimzi-entity-operator-metrics-test created
podmonitor.monitoring.coreos.com/strimzi-bridge-metrics-test created
podmonitor.monitoring.coreos.com/strimzi-kafka-and-cruise-control-metrics-test created
>>> Installing sessions/002/install/030-grafana-operator.yaml
namespace/grafana created
customresourcedefinition.apiextensions.k8s.io/grafanadashboards.integreatly.org created
customresourcedefinition.apiextensions.k8s.io/grafanadatasources.integreatly.org created
customresourcedefinition.apiextensions.k8s.io/grafananotificationchannels.integreatly.org created
customresourcedefinition.apiextensions.k8s.io/grafanas.integreatly.org created
serviceaccount/controller-manager created
role.rbac.authorization.k8s.io/leader-election-role created
clusterrole.rbac.authorization.k8s.io/manager-role configured
clusterrole.rbac.authorization.k8s.io/metrics-reader unchanged
clusterrole.rbac.authorization.k8s.io/proxy-role unchanged
rolebinding.rbac.authorization.k8s.io/leader-election-rolebinding created
clusterrolebinding.rbac.authorization.k8s.io/manager-rolebinding unchanged
clusterrolebinding.rbac.authorization.k8s.io/proxy-rolebinding unchanged
service/controller-manager-metrics-service created
configmap/manager-config created
deployment.apps/controller-manager created
>>> Installing sessions/002/install/031-grafana-server.yaml
namespace/grafana unchanged
grafana.integreatly.org/grafana created
service/grafana created
ingress.networking.k8s.io/grafana created
grafanadatasource.integreatly.org/prometheus created
>>> Installing sessions/002/install/032-grafana-strimzi.yaml
grafanadashboard.integreatly.org/strimzi-operators created
grafanadashboard.integreatly.org/strimzi-kafka created
>>> Installing sessions/002/install/040-kube-state-metrics.yaml
serviceaccount/kube-state-metrics unchanged
clusterrole.rbac.authorization.k8s.io/kube-state-metrics unchanged
clusterrolebinding.rbac.authorization.k8s.io/kube-state-metrics unchanged
deployment.apps/kube-state-metrics unchanged
service/kube-state-metrics unchanged
podmonitor.monitoring.coreos.com/kube-state-metrics created
grafanadashboard.integreatly.org/kube-state-metrics created
>>> Installing sessions/002/install/050-node-exporter.yaml
service/node-exporter created
daemonset.apps/node-exporter created
servicemonitor.monitoring.coreos.com/node-exporter created
grafanadashboard.integreatly.org/node-exporter created
```

When all Grafana is ready, you can access the dashboards from [http://grafana.f12i.io](http://grafana.f12i.io).

> [!IMPORTANT]
> Enable the Nginx ingress controller with `--enable-ssl-passthrough` flag and add the `/etc/hosts` mapping.

It is also possible to create alerting rules to provide notifications about specific conditions observed in metrics.
This is managed by Prometheus Alert Manager, but it is not described here.
