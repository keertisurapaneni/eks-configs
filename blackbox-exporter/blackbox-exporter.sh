#!/bin/bash

set -e
set -o pipefail

# Usage
helpFunction() {
  echo
  echo "Usage: $0 -p <profile> -x <value> -r <region> -c <cluster name> -f <health check file> -m yes"
  echo
  echo -e "\t-p: Required: AWS profile name in your local config"
  echo -e "\t-x: Optional: Default is aws-vault, enter aws-okta to change"
  echo -e "\t-r: Optional: Region where EKS cluster exists..Default is us-east-1"
  echo -e "\t-c: Required: Cluster name"
  echo -e "\t-f: Required: Health check YAML file. Should be present in configs folder"
  echo -e "\t-m: Optional: Select yes if you have updated the modules.yaml file, valid values are yes/y"
  echo
  exit 1
}

# Set default values
AWS_REGION="us-east-1"
AUTH="aws-vault"
NAMESPACE="prometheus"

# User values
while getopts p:r:x:c:m:f: flag; do
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
    c) CLUSTER="${OPTARG}" ;;
    m)
      UPDATE_MODULES="${OPTARG}"
      [[ "$UPDATE_MODULES" == "yes" || "$UPDATE_MODULES" == "y" ]] || { 
        echo
        echo "Invalid option for -m. Please check usage."
        helpFunction
      }
      ;;
    f) 
      HEALTH_CHECK_FILE="${OPTARG}" 
      echo "$HEALTH_CHECK_FILE"
      if [[ ! `echo $HEALTH_CHECK_FILE | grep -w 'y(a)ml\|configs'` ]]; then
        echo
        echo "Invalid option for -f. Provided file does not have a valid yaml extension (yaml or yml) or is not present in configs folder"
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
if [[ -z "$AWS_ACCOUNT" ]] || [[ -z "$CLUSTER" ]] || [[ -z "$HEALTH_CHECK_FILE" ]]; then
  echo
  echo "Required parameters are empty. Please check usage"
  helpFunction
fi

echo
echo "EKS Cluster: $CLUSTER"
echo "Generate kubeconfig.."
if [[ ! $($AUTH exec $AWS_ACCOUNT -- aws eks update-kubeconfig --name $CLUSTER --region $AWS_REGION) ]]; then
  echo "Please provide correct details..exiting"
  echo
  exit 1
fi

echo
echo "-------------------------------------------------------------------"
echo "Checking if Blackbox exporter is installed.."
echo
if [[ ! $($AUTH exec $AWS_ACCOUNT -- kubectl get configmap -n prometheus | grep "prometheus-blackbox-exporter") ]]; then
  echo "Installing Blackbox exporter for uptime check monitoring"
  echo
  $AUTH exec $AWS_ACCOUNT -- helm repo update
  $AUTH exec $AWS_ACCOUNT -- helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter -n $NAMESPACE -f ./modules.yaml
else
  echo "Blackbox exporter is already installed"
fi
# https://talks.cloudify.co/endpoint-monitoring-with-prometheus-and-blackbox-exporter-301ca7e49d6d

# Update prometheus-blackbox-exporter config map with the new modules added to modules.yaml
if [ ! -z "$UPDATE_MODULES" ]; then
  echo
  echo "-------------------------------------------------------------------"
  echo "Adding/updating Blackbox exporter modules"
  echo
  $AUTH exec $AWS_ACCOUNT -- helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter -n $NAMESPACE -f ./modules.yaml
fi

# Update prometheus-for-amp-server config map with new custom URL checks
echo
echo "-------------------------------------------------------------------"
echo "Updating URLs for uptime checks"
echo
$AUTH exec $AWS_ACCOUNT -- helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
$AUTH exec $AWS_ACCOUNT -- helm upgrade --install --reuse-values prometheus-for-amp prometheus-community/prometheus -n $NAMESPACE -f ./$HEALTH_CHECK_FILE
# ax lp-nonprod -- helm upgrade --install --reuse-values prometheus-for-amp prometheus-community/prometheus -n prometheus -f endpoint-alerts.yaml
# ax lp-nonprod -- kubectl delete pod prometheus-for-amp-server-0 -n prometheus      