# Install and/or update Blackbox Exporter synthetics

## To create uptime checks for URLs in a specific cluster:

Pre-requisites:
- Add a custom YAML file defining the URLs you want to monitor in configs sub-folder
- It is suggested to name the file as <cluster-name>.yaml so we know which cluster the synthetics are being deployed to
- You can add multiple jobs in the same file (each job can reference a different module)

> :memo: **Note:** Refer to example.yaml file or any of the existing files in configs folder to get an idea on how to create a custom YAML file.

`./blackbox-exporter.sh -p lp-nonprod -c lonelyplanet-nonprod -f configs/lonelyplanet-nonprod.yaml`

## To deploy a new module to Blackbox exporter, modify the modules.yaml file and run the command with -m argument:

`./blackbox-exporter.sh -p lp-nonprod -c lonelyplanet-nonprod -f configs/lonelyplanet-nonprod.yaml -m yes`

> :memo: **Note:** Check out this [example yaml](https://github.com/prometheus/blackbox_exporter/blob/fbbe03965a547cabdfb6782f65eedd08712acce7/example.yml) to view all options to add to modules.yaml file

This deployment restarts the blackbox-exporter pod. Sometimes if it doesn't like a regex or formatting, the pod for blackbox-exporter will go into a CrashLoopBackOff. Make sure to check the status

Example: `ax lp-nonprod -- kubectl get pods -n prometheus -w | grep blackbox`
