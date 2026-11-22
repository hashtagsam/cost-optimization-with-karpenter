#!/usr/bin/env bash
# Price every running node of the cluster at LIVE rates (Spot price in its AZ,
# or on-demand list price) and compare with a static, peak-sized node group.
# Read-only. Needs: aws CLI, jq.
# Usage: scripts/cost-report.sh <cluster> <region> [baseline_type] [baseline_count]
set -euo pipefail

CLUSTER=${1:?cluster name}
REGION=${2:?region}
BASE_TYPE=${3:-m6i.xlarge}
BASE_COUNT=${4:-6}

on_demand() { # USD/hour for Linux, shared tenancy (Price List API is served from us-east-1)
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 --output text \
    --filters Type=TERM_MATCH,Field=instanceType,Value="$1" \
    Type=TERM_MATCH,Field=regionCode,Value="$REGION" \
    Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
    Type=TERM_MATCH,Field=tenancy,Value=Shared \
    Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
    Type=TERM_MATCH,Field=capacitystatus,Value=Used \
    --query 'PriceList[0]' |
    jq -r '[.terms.OnDemand[].priceDimensions[].pricePerUnit.USD | tonumber] | max'
}

spot() { # current Spot price for a type in one AZ
  aws ec2 describe-spot-price-history --region "$REGION" --output text \
    --instance-types "$1" --availability-zone "$2" --product-descriptions Linux/UNIX \
    --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --max-items 1 \
    --query 'SpotPriceHistory[0].SpotPrice'
}

declare -A OD SP
rows=""
while read -r itype az life pool; do
  [[ -n ${OD[$itype]:-} ]] || OD[$itype]=$(on_demand "$itype")
  price=${OD[$itype]}
  if [[ $life == spot ]]; then
    [[ -n ${SP[$itype/$az]:-} ]] || SP[$itype/$az]=$(spot "$itype" "$az")
    price=${SP[$itype/$az]}
  fi
  rows+="$pool $itype $az $life $price ${OD[$itype]}"$'\n'
done < <(aws ec2 describe-instances --region "$REGION" --output text \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" Name=instance-state-name,Values=running \
  --query "Reservations[].Instances[].[InstanceType, Placement.AvailabilityZone, InstanceLifecycle || 'on-demand', Tags[?Key=='karpenter.sh/nodepool'].Value | [0] || 'system']")

[[ -n $rows ]] || { echo "No running nodes for cluster $CLUSTER in $REGION" >&2; exit 1; }
base_price=$(on_demand "$BASE_TYPE")

printf '%s' "$rows" | awk -v bt="$BASE_TYPE" -v bc="$BASE_COUNT" -v bp="$base_price" '
  BEGIN { printf "%-9s %-14s %-12s %-10s %9s\n", "POOL", "INSTANCE", "AZ", "CAPACITY", "$/HR" }
  { printf "%-9s %-14s %-12s %-10s %9.4f\n", $1, $2, $3, $4, $5; actual += $5; od += $6; n++; if ($4 == "spot") s++ }
  END {
    base = bp * bc
    printf "\nNodes: %d (%d spot)\n", n, s
    printf "Compute $/hr now:            %8.4f\n", actual
    printf "Same nodes, all on-demand:   %8.4f  (Spot saves %.0f%%)\n", od, (1 - actual / od) * 100
    printf "Baseline %d x %s:     %8.4f  (Karpenter saves %.0f%%)\n", bc, bt, base, (1 - actual / base) * 100
    printf "Monthly (x730): %.0f vs %.0f USD\n", actual * 730, base * 730
    print "EC2 compute only, list prices, point in time - a lab measurement, not a bill."
  }'