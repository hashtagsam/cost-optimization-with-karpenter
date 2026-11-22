#!/usr/bin/env bash
# Safe teardown. Karpenter's EC2 instances are NOT in Terraform state, so a
# plain `terraform destroy` hangs on subnets they still use and leaves them
# billing. Order: Karpenter removes its nodes -> destroy -> check for orphans.
set -euo pipefail

TF="terraform -chdir=terraform/envs/dev"
CLUSTER=$($TF output -raw cluster_name)
REGION=$($TF output -raw region)

read -r -p "Type '$CLUSTER' to destroy it: " answer
[[ $answer == "$CLUSTER" ]] || { echo "Aborted."; exit 1; }

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
  echo "==> Deleting NodePools; Karpenter drains and terminates its nodes"
  kubectl delete nodepools --all
  until [[ -z $(kubectl get nodeclaims -o name 2>/dev/null) ]]; do sleep 15; echo "    waiting for nodes..."; done
fi

echo "==> terraform destroy"
$TF destroy

echo "==> Checking for orphaned instances"
left=$(aws ec2 describe-instances --region "$REGION" --output text \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[].Instances[].InstanceId')
if [[ -n $left ]]; then
  echo "Orphaned instances still billing - terminate them: $left"
  exit 1
fi
echo "Clean - nothing left billing."