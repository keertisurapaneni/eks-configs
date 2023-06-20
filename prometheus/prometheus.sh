#!/bin/bash

set -e
set -o pipefail

# Usage
helpFunction() {
  echo
  echo "Usage: $0 -p <profile> -x <value> -r <region> -b yes"
  echo
  echo -e "\t-p: Required: AWS profile name in your local config"
  echo -e "\t-x: Optional: Default is aws-vault, enter aws-okta to change"
  echo -e "\t-r: Optional: Region where EKS cluster exists..Default is us-east-1"
  echo -e "\t-b: Optional: Install blackbox-exporter and/or setup/update uptime checks for URLs, valid values are yes/y"
  echo -e "\t-f: Conditional: Should be passed when -b  is passed. Health check YAML file. Should be present in ../blackbox-exporter/configs folder"
  echo
  exit 1
}

# Set default values
AWS_REGION="us-east-1"
AUTH="aws-vault"

# User values
while getopts p:r:x:b:f: flag; do
  case "${flag}" in
    p) AWS_ACCOUNT="${OPTARG}" ;;
    r) AWS_REGION="${OPTARG}" ;;
    x)
      AUTH="${OPTARG}"
      [[ "$AUTH" == "aws-okta" || "$AUTH" == "aws-vault" ]] || {
        echo
        echo "Invalid option for -x. Please check usage."
        helpFunction
      }
      ;;
    b)
      BLACKBOX_EXPORTER="${OPTARG}"
      [[ "$BLACKBOX_EXPORTER" == "yes" || "$BLACKBOX_EXPORTER" == "y" ]] || {
        echo
        echo "Invalid option for -b. Please check usage."
        helpFunction
      }
      ;;
    f) 
      HEALTH_CHECK_FILE="${OPTARG}" 
      if [[ ! `echo $HEALTH_CHECK_FILE | grep -w 'y(a)ml\|blackbox-exporter\|configs'` ]]; then
        echo
        echo "Invalid option for -f. Provided file does not have a valid yaml extension (yaml or yml) or is not present in ../blackbox-exporter/configs folder"
        echo
        exit 1
      elif [[ ! -f "$HEALTH_CHECK_FILE" ]]; then
        echo 
        echo "Invalid option for -f. Provided YAML file doesn't exist"
        helpFunction
      fi
      ;;
    ?) helpFunction ;; # Print helpFunction in case parameter is non-existent
  esac
done

# Print helpFunction in case parameters are empty
if [ -z "$AWS_ACCOUNT" ]; then
  echo
  echo "Required parameters are empty. Please check usage"
  helpFunction
fi

# Pass -f flag when -b flag is passed and vice versa
if [[ -z "$BLACKBOX_EXPORTER" && "$HEALTH_CHECK_FILE" ]] || [[ "$BLACKBOX_EXPORTER" && -z "$HEALTH_CHECK_FILE" ]]; then
  echo
  echo "Argument -f is required along with -b flag..please re-run the script"
  helpFunction
fi

# DONOT MODIFY
PROMETHEUS_WORKSPACE="EKS-Metrics-Workspace"
SERVICE_ACCOUNT_IAM_ROLE="EKS-AMP-ServiceAccount-Role"

# Pod
NAMESPACE="prometheus"
PROMETHEUS_POD="prometheus-for-amp-server-0"
PROMETHEUS_STATEFULSET="prometheus-for-amp-server"
PROMETHEUS_CONTAINER="prometheus-server"

# Create Prometheus workspace
WORKSPACE_EXISTS=$($AUTH exec $AWS_ACCOUNT -- aws amp list-workspaces --query "workspaces[].alias" --output text | grep "${PROMETHEUS_WORKSPACE}")
echo
if [ -z "$WORKSPACE_EXISTS" ]; then
  echo "AMP workspace doesn't exist..Creating workspace"
  AMP=$($AUTH exec $AWS_ACCOUNT -- aws amp create-workspace --alias $PROMETHEUS_WORKSPACE --region $AWS_REGION)
  echo "$AMP"
else
  echo "$PROMETHEUS_WORKSPACE workspace already exists, skipping"
fi

# Add new Helm chart repositories
echo
$AUTH exec $AWS_ACCOUNT -- helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Run on each cluster
EKS_CLUSTERS=$($AUTH exec $AWS_ACCOUNT -- aws eks list-clusters --query 'clusters' --output text | tr '\t' '\n')
if [ ! -z "$EKS_CLUSTERS" ]; then
  for CLUSTER in $EKS_CLUSTERS; do
    echo
    echo "-------------------------------------------------------------------"
    echo "EKS Cluster: $CLUSTER"
    echo "Generate kubeconfig.."
    $AUTH exec $AWS_ACCOUNT -- aws eks update-kubeconfig --name $CLUSTER --region $AWS_REGION

    # Create IAM role if not present
    SERVICE_ACCOUNT_IAM_ROLE_ARN=$($AUTH exec $AWS_ACCOUNT -- aws iam get-role --role-name $SERVICE_ACCOUNT_IAM_ROLE --query 'Role.Arn' --output text)
    echo
    if [ ! -z "$SERVICE_ACCOUNT_IAM_ROLE_ARN" ]; then
      echo "Service IAM role account already present, skipping"
    else
      echo "Creating IAM Service role for account $AWS_ACCOUNT"
      . ./iam.sh
    fi

    # Create namespace and fargate profile
    echo
    if [[ ! $($AUTH exec $AWS_ACCOUNT -- kubectl get namespace | grep "$NAMESPACE") ]]; then
      echo "Creating namespace"
      $AUTH exec $AWS_ACCOUNT -- kubectl create ns $NAMESPACE
    fi

    if [[ ! $($AUTH exec $AWS_ACCOUNT -- eksctl get fargateprofile --cluster $CLUSTER --name $NAMESPACE | grep "$NAMESPACE") ]]; then
      echo "Creating fargate profile"
      $AUTH exec $AWS_ACCOUNT -- eksctl create fargateprofile --cluster $CLUSTER --name $NAMESPACE --namespace $NAMESPACE
    fi
    echo
    echo "-------------------------------------------------------------------"
    echo "Integrating cluster with EFS.."
    FILE_SYSTEM_ID=$($AUTH exec $AWS_ACCOUNT -- aws efs describe-file-systems | jq -r '.FileSystems[] | select(.Name=="eks-efs").FileSystemId')
    sed "s/EFS_VOLUME_ID/$FILE_SYSTEM_ID/g" efs-pvc.yaml >tmp.yaml
    echo
    $AUTH exec $AWS_ACCOUNT -- kubectl apply -f tmp.yaml
    rm tmp.yaml
    echo
    $AUTH exec $AWS_ACCOUNT -- kubectl get pvc -n prometheus | grep "storage-volume-prometheus-for-amp-server-0"
    echo
    $AUTH exec $AWS_ACCOUNT -- kubectl get pv

    # Install a new Prometheus server to send metrics to your Prometheus workspace
    echo
    echo "-------------------------------------------------------------------"
    echo "Checking if Prometheus is installed"
    if [[ ! $($AUTH exec $AWS_ACCOUNT -- kubectl get configmap -n prometheus | grep "prometheus-for-amp-server") ]]; then
      echo "Installing Prometheus service in cluster $CLUSTER"
      WORKSPACE_ID=$($AUTH exec $AWS_ACCOUNT -- aws amp list-workspaces --alias $PROMETHEUS_WORKSPACE | jq .workspaces[0].workspaceId -r)
      AWS_ACCOUNT_ID=$($AUTH exec $AWS_ACCOUNT -- aws sts get-caller-identity --query "Account" --output text)
      SERVICE_ACCOUNT_IAM_ROLE_ARN=$($AUTH exec $AWS_ACCOUNT -- aws iam get-role --role-name $SERVICE_ACCOUNT_IAM_ROLE --query 'Role.Arn' --output text)

      echo
      $AUTH exec $AWS_ACCOUNT -- helm upgrade --install prometheus-for-amp prometheus-community/prometheus -n $NAMESPACE -f ./amp_ingest_override_values.yaml \
        --set serviceAccounts.server.annotations."eks\.amazonaws\.com/role-arn"="${SERVICE_ACCOUNT_IAM_ROLE_ARN}" \
        --set server.remoteWrite[0].url="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${WORKSPACE_ID}/api/v1/remote_write" \
        --set server.remoteWrite[0].sigv4.region=${AWS_REGION} \
        --set prometheus-node-exporter.enabled=false \
        --set prometheus-pushgateway.enabled=false

      # Modify resource limits for prometheus-server container
      $AUTH exec $AWS_ACCOUNT -- kubectl set resources -n $NAMESPACE statefulset $PROMETHEUS_STATEFULSET -c=$PROMETHEUS_CONTAINER --limits=cpu="1",memory=8Gi --requests=cpu=200m,memory=8Gi
      # Modify EFS volume mount permissions using init container
      $AUTH exec $AWS_ACCOUNT -- kubectl -n $NAMESPACE patch statefulset $PROMETHEUS_STATEFULSET --patch '{"spec": {"template": {"spec": {"initContainers": [{"name": "prometheus-data-permission-fix","image": "busybox","command": ["/bin/chmod", "-R", "777", "/data"],"volumeMounts": [{ "name": "storage-volume", "mountPath": "/data" }],"securityContext": {"runAsGroup": 0,"runAsNonRoot": false,"runAsUser": 0}}]}}}}'
      $AUTH exec $AWS_ACCOUNT -- kubectl delete pod $PROMETHEUS_POD --namespace $NAMESPACE

      # Shows status of pods
      sleep 90
      $AUTH exec $AWS_ACCOUNT -- kubectl get pods --namespace $NAMESPACE

      # Setup Blackbox exporter if -b is passed as user argument
      if [ ! -z "$BLACKBOX_EXPORTER" ]; then
        cd ../blackbox-exporter
        . ./blackbox-exporter.sh
        cd ../prometheus
      fi
    else
      echo "Prometheus is already installed..exiting"
    fi
  done
else
  echo "No EKS clusters in this account/region..exiting"
  exit 1
fi