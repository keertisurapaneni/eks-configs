# Install Amazon managed Prometheus

## To install Prometheus in all clusters in an account:

`./prometheus.sh -p lp-nonprod`


## To install Prometheus and Blackbox exporter together in an account:

> :warning: **Note:** Run this only if there is a single cluster in an account, otherwise it will install and setup Blackbox exporter in all clusters with the same synthetics which is not ideal. For a multi-cluster account, install Prometheus using `./prometheus.sh -p lp-nonprod` and then run `../blackbox-exporter/blackbox-exporter.sh` separately on a specific cluster.

Pre-requisites:
- Add a custom YAML file defining the URLs you want to monitor in ../blackbox-exporter/configs folder
- It is suggested to name the file as <cluster-name>.yaml so we know which cluster the synthetics are being deployed to
- You can add multiple jobs in the same file (each job can reference a different module)
- You need to pass both the -b and -f argument 

> :memo: **Note:** Refer to example.yaml file or any of the existing files in ../blackbox-exporter/configs folder to get an idea on how to create a custom YAML file.

`./prometheus.sh -p lp-nonprod -b yes -f ../blackbox-exporter/configs/lonelyplanet-nonprod.yaml`

