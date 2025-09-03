## Monitoring Kafka metrics

First, use [this session](/sessions/001) to deploy a Kafka cluster on Kubernetes.

> [!IMPORTANT]
> If you are using Minikube you need to enable the Nginx ingress controller: 
> ```sh
> minikube addons enable ingress
> ```
> Then, run the following command to enable SSL passthrough every time you restart Minikube: 
> ```sh
> kubectl patch deploy -n ingress-nginx ingress-nginx-controller --type json \
>   -p '[{"op":"add", "path":"/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]'
> ```
> Finally, make sure to add Minikube's IP to your hosts file:
> ```sh
> sudo echo "192.168.49.2 prometheus.f12i.io grafana.f12i.io" >> /etc/hosts
> ```

When the cluster is ready, install Prometheus, Grafana and Strimzi dashboards.

```sh
$ for f in sessions/002/install/*.yaml; do
  echo ">>> Installing $f"
  envsubst < "$f" | kubectl create -f -
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

When Grafana pod is ready, you can access the dashboards from [http://grafana.f12i.io](http://grafana.f12i.io).

> [!NOTE]  
> If you can't access Grafana trough the ingress URL, then use Minikube port forwarding:
> ```shell
> kubectl -n grafana port-forward service/grafana 8000:80
> ```
> Then point your browser to http://localhost:8000.

Only the Cluster Operator and Kafka dashboards are included, but you can easily [add the other dashboards](/sessions/002/install/032-grafana-strimzi.yaml).

It is also possible to create alerting rules to provide notifications about specific conditions observed in metrics.
This is managed by Prometheus Alert Manager, but it is out of scope for this session.
