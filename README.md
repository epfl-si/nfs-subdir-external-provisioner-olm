# NFS subdir external provisioner OLM operator


https://sdk.operatorframework.io/docs/building-operators/helm/tutorial/

Initialized with:
```sh
operator-sdk init --plugins helm --domain epfl.ch --group nfs --version v1alpha1 --kind NfsSubdirProvisioner --helm-chart-repo https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ --helm-chart nfs-subdir-external-provisioner --helm-chart-version 4.0.18
```
