#!/usr/bin/env bash
#
# =============================================================================
# eks-upgrade-precheck.sh
#
# Purpose:
#   Check the most important prerequisites BEFORE upgrading an Amazon EKS
#   cluster to the next Kubernetes minor version (in-place upgrade).
#
#   This script is READ-ONLY. It only runs "describe", "list", "get" and
#   similar commands. It NEVER modifies, deletes, or upgrades anything.
#
# Based on the official AWS guidance:
#   [1] Update existing cluster:
#       https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html
#   [2] Best Practices for Cluster Upgrades:
#       https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html
#   [3] Auto Mode cluster IAM role:
#       https://docs.aws.amazon.com/eks/latest/userguide/auto-cluster-iam-role.html
#   [4] Verify add-on version compatibility:
#       https://docs.aws.amazon.com/eks/latest/userguide/addon-compat.html
#
# What it checks:
#   Step 1 - Cluster exists, is ACTIVE, and whether it is EKS Auto Mode
#   Step 2 - Target version is exactly one minor version ahead (in-place rule)
#   Step 3 - Networking: subnet free IPs (need up to 5) AND security groups exist
#   Step 4 - Cluster IAM role: trust policy + required managed policies
#            (the required set differs for Auto Mode vs Standard mode)
#   Step 5 - KMS permission for secret encryption (only if encryption is on)
#   Step 6 - Upgrade Insights (deprecated/removed API usage, health issues)
#   Step 7 - Managed node groups: status, AMI, version skew vs control plane
#   Step 8 - EKS Add-ons compatibility with the TARGET Kubernetes version
#
# Requirements:
#   - AWS CLI v2, configured with credentials (ReadOnly is enough and preferred)
#   - jq (command-line JSON processor)
# =============================================================================

# ---- Safety settings --------------------------------------------------------
# -u : treat unset variables as an error (catches typos in variable names)
# -o pipefail : a pipeline fails if ANY command in it fails, not just the last
# NOTE: we intentionally do NOT use "set -e" because we want to run ALL checks
#       even when one of them fails, and then print a summary at the end.
set -uo pipefail


# =============================================================================
# DISCLAIMER (read before relying on this script)
# =============================================================================
print_disclaimer() {
  cat <<'EOF'
-----------------------------------------------------------------------------
  DISCLAIMER - PLEASE READ
-----------------------------------------------------------------------------
  * This script is READ-ONLY. It never changes, deletes, or upgrades anything.
  * It is a HELPER, not a guarantee. Passing all checks does NOT promise a
    trouble-free upgrade. Always read the EKS/Kubernetes release notes for the
    target version and test in a NON-PRODUCTION cluster first.
  * EKS upgrades are ONE-WAY. You cannot downgrade a cluster after upgrading.
  * Use ReadOnly / least-privilege AWS credentials to run this script.
  * Some checks are skipped (with a WARNING) if your credentials lack a
    permission, or if a feature is not supported in your CLI/region. A skipped
    check is NOT a pass - verify it manually.
  * Add-on / IAM / version-skew rules evolve. This script reflects AWS docs at
    the time of writing; confirm against the current AWS documentation.
-----------------------------------------------------------------------------
EOF
}


# =============================================================================
# CONFIGURATION via ENVIRONMENT VARIABLES
# -----------------------------------------------------------------------------
# You only have to set CLUSTER_NAME. Everything else has a sensible default.
#
# Example usage:
#   export CLUSTER_NAME="my-prod-cluster"
#   export AWS_REGION="us-east-1"
#   export TARGET_VERSION="1.31"        # optional: the version you plan to go to
#   export AWS_PROFILE="my-readonly"    # optional: named profile to use
#   ./eks-upgrade-precheck.sh
# =============================================================================

# The name of the EKS cluster you want to check (REQUIRED).
CLUSTER_NAME="${CLUSTER_NAME:-}"

# The AWS region the cluster lives in. Falls back to AWS_DEFAULT_REGION, then us-east-1.
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# The Kubernetes version you intend to upgrade TO (e.g. "1.31").
# If left empty, the script will auto-suggest "current minor + 1".
TARGET_VERSION="${TARGET_VERSION:-}"

# Minimum number of free IP addresses EKS needs per subnet to perform an upgrade.
# AWS documents "up to five". We use 5 as the safe threshold.
MIN_FREE_IPS="${MIN_FREE_IPS:-5}"

# Build the common AWS CLI argument string (region + optional profile).
AWS_ARGS=(--region "${AWS_REGION}" --output json)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_ARGS+=(--profile "${AWS_PROFILE}")
fi


# =============================================================================
# PRETTY OUTPUT HELPERS
# -----------------------------------------------------------------------------
# Color codes + emojis make the output easy to scan. Colors are disabled
# automatically if output is not a terminal (e.g. when piped to a file).
# =============================================================================
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"
  C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"; C_BLUE="\033[36m"
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""
fi

# Emojis used to highlight each status (work in most modern terminals).
E_PASS="✅"; E_FAIL="❌"; E_WARN="⚠️ "; E_INFO="ℹ️ "

# Arrays that collect results so we can print a Summary at the very end.
PASSED=()    # things that are OK
FAILED=()    # things that MUST be fixed before upgrading
WARNINGS=()  # things to review, but not necessarily blocking

record_pass() { PASSED+=("$1");   echo -e "  ${C_GREEN}${E_PASS} [PASS]${C_RESET} $1"; }
record_fail() { FAILED+=("$1");   echo -e "  ${C_RED}${E_FAIL} [FAIL]${C_RESET} $1"; }
record_warn() { WARNINGS+=("$1"); echo -e "  ${C_YELLOW}${E_WARN}[WARN]${C_RESET} $1"; }
info()        { echo -e "  $1"; }

# header "emoji" "title" -> a section header for each step
header() { echo -e "\n${C_BOLD}${C_BLUE}$1 == $2 ==${C_RESET}"; }


# =============================================================================
# PRE-FLIGHT: make sure required tools and inputs are present.
# =============================================================================
print_disclaimer

echo -e "${C_BOLD}🚀 ==== Start checking cluster's status before upgrading ==== 🚀${C_RESET}"

# 1) The AWS CLI must be installed.
if ! command -v aws >/dev/null 2>&1; then
  echo -e "${C_RED}${E_FAIL} ERROR:${C_RESET} AWS CLI is not installed. Install AWS CLI v2 and retry."
  exit 1
fi

# 2) jq must be installed (used to parse JSON responses cleanly).
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${C_RED}${E_FAIL} ERROR:${C_RESET} 'jq' is not installed. Install it (e.g. 'brew install jq') and retry."
  exit 1
fi

# 3) CLUSTER_NAME must be provided.
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo -e "${C_RED}${E_FAIL} ERROR:${C_RESET} CLUSTER_NAME is not set."
  echo    "       Example: export CLUSTER_NAME=my-cluster && ./eks-upgrade-precheck.sh"
  exit 1
fi


# =============================================================================
# IDENTITY / CLUSTER INFO
# -----------------------------------------------------------------------------
# Show who we are, where we are pointing, and key cluster facts (including
# whether the cluster runs in EKS Auto Mode). This avoids the classic mistake
# of running checks against the wrong account or region.
# =============================================================================
header "📋" "Cluster Info"

# Get the caller identity (which IAM principal / account these credentials use).
CALLER_JSON="$(aws "${AWS_ARGS[@]}" sts get-caller-identity 2>/dev/null)"
if [[ -z "${CALLER_JSON}" ]]; then
  echo -e "${C_RED}${E_FAIL} ERROR:${C_RESET} Unable to call AWS. Check your credentials and region."
  exit 1
fi
ACCOUNT_ID="$(echo "${CALLER_JSON}" | jq -r '.Account')"
CALLER_ARN="$(echo "${CALLER_JSON}" | jq -r '.Arn')"

# Fetch the full cluster description ONCE and reuse it for several checks.
CLUSTER_JSON="$(aws "${AWS_ARGS[@]}" eks describe-cluster --name "${CLUSTER_NAME}" 2>/dev/null)"
if [[ -z "${CLUSTER_JSON}" ]]; then
  echo -e "${C_RED}${E_FAIL} ERROR:${C_RESET} Cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'."
  echo    "       Double-check CLUSTER_NAME and AWS_REGION."
  exit 1
fi

CLUSTER_ARN="$(echo "${CLUSTER_JSON}"      | jq -r '.cluster.arn')"
CLUSTER_STATUS="$(echo "${CLUSTER_JSON}"   | jq -r '.cluster.status')"
CURRENT_VERSION="$(echo "${CLUSTER_JSON}"  | jq -r '.cluster.version')"
CLUSTER_ROLE_ARN="$(echo "${CLUSTER_JSON}" | jq -r '.cluster.roleArn')"

# Detect EKS Auto Mode. When Auto Mode is on, cluster.computeConfig.enabled=true.
# This drives which IAM policies are required (Step 4) and how add-ons behave.
AUTO_MODE="$(echo "${CLUSTER_JSON}" | jq -r '.cluster.computeConfig.enabled // false')"
if [[ "${AUTO_MODE}" == "true" ]]; then
  MODE_LABEL="Auto Mode"
  MODE_SHORT="Auto"
else
  MODE_LABEL="Standard"
  MODE_SHORT="Standard"
fi

info "AWS Account ID              : ${ACCOUNT_ID}"
info "Region                      : ${AWS_REGION}"
info "Caller Identity (you)       : ${CALLER_ARN}"
info "Cluster ARN                 : ${CLUSTER_ARN}"
info "Current EKS cluster version : ${CURRENT_VERSION}"
info "Cluster mode                : ${C_BOLD}${MODE_LABEL}${C_RESET}"

# If the user did not specify TARGET_VERSION, suggest current minor + 1.
# (EKS only allows ONE minor version jump at a time.)
if [[ -z "${TARGET_VERSION}" ]]; then
  CUR_MAJOR="${CURRENT_VERSION%%.*}"
  CUR_MINOR="${CURRENT_VERSION#*.}"
  TARGET_VERSION="${CUR_MAJOR}.$((CUR_MINOR + 1))"
  info "Target version : ${TARGET_VERSION} ${C_YELLOW}(auto-suggested: current + 1 minor)${C_RESET}"
else
  info "Target version : ${TARGET_VERSION} (from TARGET_VERSION env var)"
fi


# =============================================================================
# STEP 1: Cluster must be ACTIVE
# -----------------------------------------------------------------------------
# You cannot upgrade a cluster that is still creating, updating, or in a
# failed/degraded state.
# =============================================================================
header "1️⃣" "Step 1: Cluster status is ACTIVE"
if [[ "${CLUSTER_STATUS}" == "ACTIVE" ]]; then
  record_pass "Cluster status is ACTIVE."
else
  record_fail "Cluster status is '${CLUSTER_STATUS}', not ACTIVE. Wait until it is ACTIVE before upgrading."
fi


# =============================================================================
# STEP 2: Target version is exactly ONE minor version ahead
# -----------------------------------------------------------------------------
# EKS in-place upgrades move only one minor version at a time
# (e.g. 1.30 -> 1.31). Skipping versions (1.30 -> 1.32) is not allowed.
# =============================================================================
header "2️⃣" "Step 2: Upgrade jumps only one minor version"
CUR_MAJOR="${CURRENT_VERSION%%.*}"
CUR_MINOR="${CURRENT_VERSION#*.}"
TGT_MAJOR="${TARGET_VERSION%%.*}"
TGT_MINOR="${TARGET_VERSION#*.}"

if [[ "${TGT_MAJOR}" == "${CUR_MAJOR}" && "${TGT_MINOR}" == "$((CUR_MINOR + 1))" ]]; then
  record_pass "Target ${TARGET_VERSION} is exactly one minor ahead of ${CURRENT_VERSION}."
else
  record_fail "Target ${TARGET_VERSION} is not exactly one minor ahead of ${CURRENT_VERSION}. EKS upgrades ONE minor version at a time (e.g. ${CUR_MAJOR}.${CUR_MINOR} -> ${CUR_MAJOR}.$((CUR_MINOR + 1)))."
fi


# =============================================================================
# STEP 3: Networking - subnet free IPs AND security groups exist
# -----------------------------------------------------------------------------
# EKS needs up to 5 free IPs in the cluster subnets to create new control-plane
# network interfaces during the upgrade. The interfaces may land in different
# subnets than today, so the cluster's security groups must also still exist
# and allow required cluster communication. If subnets are missing, low on IPs,
# or the security groups are gone, the update can FAIL. (Ref [1])
# =============================================================================
header "3️⃣" "Step 3: Networking Review"

# ---- 3a. Subnet free IP addresses ------------------------------------------
SUBNET_IDS="$(echo "${CLUSTER_JSON}" | jq -r '.cluster.resourcesVpcConfig.subnetIds[]')"
SUBNET_JSON="$(aws "${AWS_ARGS[@]}" ec2 describe-subnets --subnet-ids ${SUBNET_IDS} 2>/dev/null)"

SUBNET_OK="skip"   # skip | pass | fail  (used to order PASS/FAIL lines after the table)
if [[ -z "${SUBNET_JSON}" ]]; then
  record_warn "Could not describe cluster subnets (missing ec2:DescribeSubnets permission?). Skipping IP check - verify manually."
else
  # Print a small readable table of subnet | AZ | free IPs.
  printf "  %-26s %-14s %s\n" "SUBNET" "AZ" "FREE_IPS"
  printf "  %-26s %-14s %s\n" "--------------------------" "------------" "--------"
  ANY_LOW="false"
  while IFS=$'\t' read -r sid az free; do
    printf "  %-26s %-14s %s\n" "${sid}" "${az}" "${free}"
    if (( free < MIN_FREE_IPS )); then ANY_LOW="true"; fi
  done < <(echo "${SUBNET_JSON}" | jq -r '.Subnets[] | [.SubnetId, .AvailabilityZone, (.AvailableIpAddressCount|tostring)] | @tsv')

  # Detect subnets that are configured on the cluster but no longer exist in EC2.
  FOUND_COUNT="$(echo "${SUBNET_JSON}" | jq '.Subnets | length')"
  CONFIG_COUNT="$(echo "${SUBNET_IDS}" | wc -w | tr -d ' ')"
  SUBNET_OK="pass"
  if (( FOUND_COUNT < CONFIG_COUNT )) || [[ "${ANY_LOW}" == "true" ]]; then
    SUBNET_OK="fail"
  fi
fi

# ---- 3b. Security groups exist ---------------------------------------------
# Gather BOTH the additional security groups and the EKS-managed cluster
# security group, then confirm each one still exists in EC2.
SG_IDS="$(echo "${CLUSTER_JSON}" | jq -r '
  ([.cluster.resourcesVpcConfig.securityGroupIds[]?]
   + [.cluster.resourcesVpcConfig.clusterSecurityGroupId // empty])
  | unique | .[]')"

SG_OK="skip"; MISSING_SG=""; SG_CSV=""
if [[ -n "${SG_IDS}" ]]; then
  SG_CSV="$(echo "${SG_IDS}" | paste -sd, -)"   # comma-joined list for messages
  EXISTING_SG="$(aws "${AWS_ARGS[@]}" ec2 describe-security-groups --group-ids ${SG_IDS} 2>/dev/null \
                  | jq -r '.SecurityGroups[].GroupId' 2>/dev/null)"
  SG_OK="pass"
  for sg in ${SG_IDS}; do
    echo "${EXISTING_SG}" | grep -q "^${sg}$" || { MISSING_SG="${MISSING_SG} ${sg}"; SG_OK="fail"; }
  done
fi

# ---- 3c. Print results together (blank line after the table) ---------------
echo ""
# Subnet verdict
case "${SUBNET_OK}" in
  pass) record_pass "All cluster subnets exist and have at least ${MIN_FREE_IPS} free IP addresses." ;;
  fail) record_fail "Cluster subnets are missing or have fewer than ${MIN_FREE_IPS} free IPs. Free up IPs or add subnets before upgrading." ;;
esac
# Security group verdict
case "${SG_OK}" in
  pass) record_pass "All cluster security groups(${SG_CSV}) exist." ;;
  fail) record_fail "Missing cluster security group(s):${MISSING_SG}. Re-create or fix VPC config before upgrading." ;;
  skip) record_warn "No security groups are recorded on the cluster VPC config. Verify cluster networking manually." ;;
esac
# Manual-review reminder (cannot be verified by an automated existence check).
record_warn "Manually confirm cluster security group rules allow required cluster communication."


# =============================================================================
# STEP 4: Cluster IAM role - trust policy + required managed policies
# -----------------------------------------------------------------------------
# The required managed policies depend on the cluster mode:
#   * Standard mode  -> needs AmazonEKSClusterPolicy
#   * Auto Mode      -> needs AmazonEKSClusterPolicy + AmazonEKSComputePolicy
#                       + AmazonEKSBlockStoragePolicy + AmazonEKSLoadBalancingPolicy
#                       + AmazonEKSNetworkingPolicy            (Ref [3])
# We list the currently attached policies and mark each required/extra one.
# =============================================================================
header "4️⃣" "Step 4: Cluster IAM role"

CLUSTER_ROLE_NAME="${CLUSTER_ROLE_ARN##*/}"
info "Cluster IAM role: ${CLUSTER_ROLE_NAME}"

# Define the required policy set based on the cluster mode.
if [[ "${AUTO_MODE}" == "true" ]]; then
  REQUIRED_POLICIES=(AmazonEKSClusterPolicy AmazonEKSComputePolicy AmazonEKSBlockStoragePolicy AmazonEKSLoadBalancingPolicy AmazonEKSNetworkingPolicy)
else
  REQUIRED_POLICIES=(AmazonEKSClusterPolicy)
fi

# ---- 4a. Trust policy (must allow eks.amazonaws.com to assume the role) -----
ROLE_JSON="$(aws "${AWS_ARGS[@]}" iam get-role --role-name "${CLUSTER_ROLE_NAME}" 2>/dev/null)"
TRUST_OK="skip"
if [[ -z "${ROLE_JSON}" ]]; then
  record_warn "Could not read IAM role '${CLUSTER_ROLE_NAME}' (missing iam:GetRole permission, or role does not exist). Verify manually."
else
  TRUSTS_EKS="$(echo "${ROLE_JSON}" \
    | jq -r '[.Role.AssumeRolePolicyDocument.Statement[]?
              | select((.Action|tostring|contains("sts:AssumeRole")))
              | (.Principal.Service // empty)]
             | flatten | index("eks.amazonaws.com") != null')"
  [[ "${TRUSTS_EKS}" == "true" ]] && TRUST_OK="pass" || TRUST_OK="fail"
fi

# ---- 4b. Attached managed policies (mark required / extra / missing) --------
ATTACHED_JSON="$(aws "${AWS_ARGS[@]}" iam list-attached-role-policies --role-name "${CLUSTER_ROLE_NAME}" 2>/dev/null)"
POLICY_OK="skip"; MISSING_REQUIRED=""
if [[ -z "${ATTACHED_JSON}" ]]; then
  record_warn "Could not list attached policies for '${CLUSTER_ROLE_NAME}' (missing iam:ListAttachedRolePolicies?). Verify manually."
else
  # Collect the attached policy names (just the names, not full ARNs).
  ATTACHED_NAMES="$(echo "${ATTACHED_JSON}" | jq -r '.AttachedPolicies[].PolicyName')"

  # 1) Walk every REQUIRED policy: present -> ✅, absent -> Missed.
  for req in "${REQUIRED_POLICIES[@]}"; do
    if echo "${ATTACHED_NAMES}" | grep -q "^${req}$"; then
      info "[${req}] ${E_PASS} Associated"
    else
      info "[${req}] ${E_FAIL} Missed (REQUIRED)"
      MISSING_REQUIRED="${MISSING_REQUIRED} ${req}"
    fi
  done

  # 2) Walk every ATTACHED policy that is NOT in the required set -> informational.
  while IFS= read -r att; do
    is_required="false"
    for req in "${REQUIRED_POLICIES[@]}"; do
      [[ "${att}" == "${req}" ]] && is_required="true" && break
    done
    [[ "${is_required}" == "false" ]] && info "[${att}] ${E_INFO} Associated but not required by this check"
  done <<< "${ATTACHED_NAMES}"

  [[ -z "${MISSING_REQUIRED}" ]] && POLICY_OK="pass" || POLICY_OK="fail"
fi

# ---- 4c. Print verdicts together (blank line after the policy list) --------
echo ""
case "${TRUST_OK}" in
  pass) record_pass "Trust policy allows eks.amazonaws.com to assume the role." ;;
  fail) record_fail "Cluster IAM role '${CLUSTER_ROLE_NAME}' does not trust eks.amazonaws.com in its assume-role policy." ;;
esac
case "${POLICY_OK}" in
  pass) record_pass "All managed policies required for ${MODE_SHORT} are attached." ;;
  fail) record_fail "Cluster role is missing required managed policies for ${MODE_SHORT}:${MISSING_REQUIRED}." ;;
esac


# =============================================================================
# STEP 5: KMS permission for secret encryption (only if it is enabled)
# -----------------------------------------------------------------------------
# If the cluster encrypts Kubernetes secrets with a KMS key, the cluster IAM
# role must be allowed to use that key. We do a best-effort existence check.
# =============================================================================
header "5️⃣" "Step 5: KMS key access for secret encryption (if enabled)"

KMS_KEY_ARN="$(echo "${CLUSTER_JSON}" \
  | jq -r '.cluster.encryptionConfig[]?.provider.keyArn // empty' | head -n1)"

if [[ -z "${KMS_KEY_ARN}" ]]; then
  record_pass "Secret encryption is not enabled; no KMS check needed."
else
  info "Encryption KMS key: ${KMS_KEY_ARN}"
  KEY_STATE="$(aws "${AWS_ARGS[@]}" kms describe-key --key-id "${KMS_KEY_ARN}" 2>/dev/null \
                | jq -r '.KeyMetadata.KeyState // empty')"
  if [[ "${KEY_STATE}" == "Enabled" ]]; then
    record_pass "KMS key for secret encryption exists and is Enabled."
    record_warn "Confirm the cluster IAM role has kms:Decrypt/kms:Encrypt on this key (key policy not fully validated here)."
  else
    record_fail "KMS key for secret encryption is not usable (state: '${KEY_STATE:-unknown}'). Fix before upgrading."
  fi
fi


# =============================================================================
# STEP 6: Upgrade Insights (deprecated/removed API usage + health)
# -----------------------------------------------------------------------------
# EKS Cluster Insights scan for deprecated/removed Kubernetes APIs and other
# upgrade-blocking issues. Any insight with status ERROR must be fixed first.
# =============================================================================
header "6️⃣" "Step 6: EKS Upgrade Insights (deprecated APIs / health)"

INSIGHTS_LIST="$(aws "${AWS_ARGS[@]}" eks list-insights --cluster-name "${CLUSTER_NAME}" 2>/dev/null)"

if [[ -z "${INSIGHTS_LIST}" ]]; then
  record_warn "Could not list cluster insights (older CLI, or not supported in this region). Check the 'Upgrade Insights' tab in the EKS console manually."
else
  ERROR_COUNT="$(echo "${INSIGHTS_LIST}"   | jq '[.insights[]? | select(.insightStatus.status=="ERROR")]   | length')"
  WARNING_COUNT="$(echo "${INSIGHTS_LIST}" | jq '[.insights[]? | select(.insightStatus.status=="WARNING")] | length')"
  PASSING_COUNT="$(echo "${INSIGHTS_LIST}" | jq '[.insights[]? | select(.insightStatus.status=="PASSING")] | length')"

  info "Insights summary: ${PASSING_COUNT} passing, ${WARNING_COUNT} warning, ${ERROR_COUNT} error"

  if (( ERROR_COUNT > 0 )); then
    while IFS= read -r name; do
      record_fail "Upgrade Insight (ERROR): ${name}  -> run: aws eks describe-insight --cluster-name ${CLUSTER_NAME} --id <id>"
    done < <(echo "${INSIGHTS_LIST}" | jq -r '.insights[]? | select(.insightStatus.status=="ERROR") | .name')
  fi

  if (( WARNING_COUNT > 0 )); then
    while IFS= read -r name; do
      record_warn "Upgrade Insight (WARNING): ${name}"
    done < <(echo "${INSIGHTS_LIST}" | jq -r '.insights[]? | select(.insightStatus.status=="WARNING") | .name')
  fi

  if (( ERROR_COUNT == 0 && WARNING_COUNT == 0 )); then
    record_pass "No ERROR or WARNING upgrade insights found."
  fi
fi


# =============================================================================
# STEP 7: Managed node groups - status, AMI, and version skew
# -----------------------------------------------------------------------------
# Best practice: bring nodes to the SAME version as the control plane BEFORE
# upgrading. The supported skew is:
#   * K8s >= 1.28 : kubelet may be up to 3 minor versions older than API server
#   * K8s <  1.28 : kubelet may be up to 2 minor versions older
# We print one table row per node group with status, version, AMI and skew. (Ref [1][2])
# =============================================================================
header "7️⃣" "Step 7: Managed node groups"

# Allowed skew depends on the control-plane (current) minor version.
if (( CUR_MINOR >= 28 )); then MAX_SKEW=3; else MAX_SKEW=2; fi

# Explain the skew policy (verbatim from the AWS best-practices guidance).
info "EKS managed node groups and nodes created by EKS Fargate Profiles support 2 minor version skew between the control plane and data plane for Kubernetes version 1.27 and below. Starting 1.28 and above, EKS managed node groups and nodes created by EKS Fargate Profiles support 3 minor version skew between control plane and data plane. For example, if your EKS control plane version is 1.28, you can safely use kubelet versions as old as 1.25. If your EKS version is 1.27, the oldest kubelet version you can use is 1.25."
echo ""

NODEGROUPS="$(aws "${AWS_ARGS[@]}" eks list-nodegroups --cluster-name "${CLUSTER_NAME}" 2>/dev/null \
              | jq -r '.nodegroups[]?')"

if [[ -z "${NODEGROUPS}" ]]; then
  record_warn "No EKS-managed node groups found. If you use self-managed nodes, Fargate, or Karpenter, verify their kubelet versions manually."
else
  # Print a table header for the node groups.
  printf "  %-33s %-10s %-9s %-26s %-19s %s\n" "NODEGROUP" "STATUS" "VERSION" "AMI_TYPE" "AMI_RELEASE" "SKEW"
  printf "  %-33s %-10s %-9s %-26s %-19s %s\n" "---------------------------------" "----------" "---------" "--------------------------" "-------------------" "----------------"

  # Collect per-node-group findings here and print them AFTER the table,
  # so the table rows are never interrupted by PASS/FAIL/WARN lines.
  NG_FAILS=(); NG_WARNS=()
  while IFS= read -r ng; do
    NG_JSON="$(aws "${AWS_ARGS[@]}" eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ng}" 2>/dev/null)"
    NG_STATUS="$(echo "${NG_JSON}"   | jq -r '.nodegroup.status // "unknown"')"
    NG_VERSION="$(echo "${NG_JSON}"  | jq -r '.nodegroup.version // "unknown"')"
    NG_AMITYPE="$(echo "${NG_JSON}"  | jq -r '.nodegroup.amiType // "n/a"')"
    NG_RELEASE="$(echo "${NG_JSON}"  | jq -r '.nodegroup.releaseVersion // "n/a"')"

    # Compute the skew (control plane minor - node minor) for the table + checks.
    NG_MINOR="${NG_VERSION#*.}"
    SKEW_LABEL="n/a"
    if [[ "${NG_MINOR}" =~ ^[0-9]+$ ]]; then
      SKEW=$(( CUR_MINOR - NG_MINOR ))
      if (( SKEW == 0 )); then
        SKEW_LABEL="${E_PASS} matched"
      elif (( SKEW <= MAX_SKEW )); then
        SKEW_LABEL="${E_WARN}-${SKEW} (ok)"
      else
        SKEW_LABEL="${E_FAIL}-${SKEW} (too old)"
      fi
    fi

    printf "  %-33s %-10s %-9s %-26s %-19s %b\n" \
      "${ng}" "${NG_STATUS}" "${NG_VERSION}" "${NG_AMITYPE}" "${NG_RELEASE}" "${SKEW_LABEL}"

    # Stash blocking / advisory findings per node group for later printing.
    if [[ "${NG_STATUS}" != "ACTIVE" ]]; then
      NG_FAILS+=("Node group '${ng}' is '${NG_STATUS}', not ACTIVE. Stabilize it before upgrading.")
    fi
    if [[ "${NG_MINOR}" =~ ^[0-9]+$ ]] && (( CUR_MINOR - NG_MINOR > MAX_SKEW )); then
      NG_FAILS+=("Node group '${ng}' (${NG_VERSION}) exceeds the allowed skew vs control plane ${CURRENT_VERSION}. Upgrade nodes first.")
    elif [[ "${NG_VERSION}" != "${CURRENT_VERSION}" ]]; then
      NG_WARNS+=("Node group '${ng}' is on ${NG_VERSION} but control plane is ${CURRENT_VERSION}. Recommended: match nodes to the control plane before upgrading.")
    fi
  done <<< "${NODEGROUPS}"

  # Now print the collected verdicts (blank line separates them from the table).
  echo ""
  (( ${#NG_FAILS[@]} > 0 )) && for msg in "${NG_FAILS[@]}"; do record_fail "${msg}"; done
  (( ${#NG_WARNS[@]} > 0 )) && for msg in "${NG_WARNS[@]}"; do record_warn "${msg}"; done
  if (( ${#NG_FAILS[@]} == 0 && ${#NG_WARNS[@]} == 0 )); then
    record_pass "All managed node groups are ACTIVE and on the control-plane version."
  fi
fi


# =============================================================================
# STEP 8: EKS Add-ons compatibility with the TARGET Kubernetes version
# -----------------------------------------------------------------------------
# EKS add-ons are NOT upgraded automatically and can only move one minor
# version at a time. For each installed add-on we ask AWS which versions are
# compatible with the TARGET version, then show the oldest/latest compatible
# version and whether the currently installed version is still compatible.
#   aws eks describe-addon-versions --addon-name <name> --kubernetes-version <target>   (Ref [4])
# =============================================================================
header "8️⃣" "Step 8: EKS Add-ons compatibility with target ${TARGET_VERSION}"

ADDONS="$(aws "${AWS_ARGS[@]}" eks list-addons --cluster-name "${CLUSTER_NAME}" 2>/dev/null \
          | jq -r '.addons[]?')"

if [[ -z "${ADDONS}" ]]; then
  record_warn "No EKS-managed add-ons found (you may be using self-managed add-ons). Verify CoreDNS, kube-proxy, and VPC CNI versions manually."
else
  # Table header: add-on | current version | oldest/latest compatible w/ target | verdict
  printf "  %-26s %-22s %-22s %-22s %s\n" "ADDON" "CURRENT" "OLDEST_COMPATABILITY" "LATEST_COMPATABILITY" "CURRENT_OK_FOR_TARGET"
  printf "  %-26s %-22s %-22s %-22s %s\n" "--------------------------" "----------------------" "----------------------" "----------------------" "---------------------"

  # Collect per-add-on warnings here; print them after the table (keeps it clean).
  ADDON_ISSUE="false"; ADDON_WARNS=()
  while IFS= read -r addon; do
    CUR_ADDON_VER="$(aws "${AWS_ARGS[@]}" eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${addon}" 2>/dev/null \
                      | jq -r '.addon.addonVersion // "unknown"')"

    # Ask AWS for all add-on versions compatible with the TARGET k8s version.
    COMPAT_JSON="$(aws "${AWS_ARGS[@]}" eks describe-addon-versions \
                    --addon-name "${addon}" --kubernetes-version "${TARGET_VERSION}" 2>/dev/null)"

    # Extract the flat list of compatible version strings (most recent first).
    COMPAT_VERSIONS="$(echo "${COMPAT_JSON}" | jq -r '.addons[0].addonVersions[]?.addonVersion' 2>/dev/null)"

    if [[ -z "${COMPAT_VERSIONS}" ]]; then
      printf "  %-26s %-22s %-22s %-22s %b\n" "${addon}" "${CUR_ADDON_VER}" "n/a" "n/a" "${E_WARN}unknown"
      ADDON_WARNS+=("Add-on '${addon}': no compatibility data returned for ${TARGET_VERSION} (verify manually).")
      ADDON_ISSUE="true"
      continue
    fi

    # AWS returns newest-first, so head=latest and tail=oldest compatible.
    LATEST_COMPAT="$(echo "${COMPAT_VERSIONS}" | head -n1)"
    OLDEST_COMPAT="$(echo "${COMPAT_VERSIONS}" | tail -n1)"

    # Is the currently installed version in the compatible list for the target?
    if echo "${COMPAT_VERSIONS}" | grep -qx "${CUR_ADDON_VER}"; then
      VERDICT="${E_PASS} yes"
    else
      VERDICT="${E_WARN}upgrade needed"
      ADDON_ISSUE="true"
    fi

    printf "  %-26s %-22s %-22s %-22s %b\n" \
      "${addon}" "${CUR_ADDON_VER}" "${OLDEST_COMPAT}" "${LATEST_COMPAT}" "${VERDICT}"
  done <<< "${ADDONS}"

  # Print verdicts after the table (blank line separates them from it).
  echo ""
  (( ${#ADDON_WARNS[@]} > 0 )) && for msg in "${ADDON_WARNS[@]}"; do record_warn "${msg}"; done
  if [[ "${ADDON_ISSUE}" == "false" ]]; then
    record_pass "All installed add-ons already have a version compatible with ${TARGET_VERSION}."
  fi
  record_warn "After the control-plane upgrade, update each add-on to a version compatible with ${TARGET_VERSION} (one minor version at a time)."
fi


# =============================================================================
# SUMMARY
# -----------------------------------------------------------------------------
# A single, human-readable recap so you can decide GO / NO-GO at a glance.
# =============================================================================
echo -e "\n${C_BOLD}🧾 ==== Summary ==== 🧾${C_RESET}"
echo -e "  Cluster : ${CLUSTER_NAME}"
echo -e "  Mode    : ${MODE_LABEL}"
echo -e "  Upgrade : ${CURRENT_VERSION}  ->  ${TARGET_VERSION}"
echo -e "  Account : ${ACCOUNT_ID}  |  Region: ${AWS_REGION}"
echo -e "  Totals  : ${C_GREEN}${#PASSED[@]} passed${C_RESET}, ${C_YELLOW}${#WARNINGS[@]} warnings${C_RESET}, ${C_RED}${#FAILED[@]} failed${C_RESET}"

echo -e "\n${C_GREEN}${C_BOLD}${E_PASS} Passed (${#PASSED[@]})${C_RESET}"
if (( ${#PASSED[@]} == 0 )); then echo "  - (none)"; else
  for item in "${PASSED[@]}"; do echo -e "  ${C_GREEN}•${C_RESET} ${item}"; done
fi

echo -e "\n${C_YELLOW}${C_BOLD}${E_WARN}Warnings to review (${#WARNINGS[@]})${C_RESET}"
if (( ${#WARNINGS[@]} == 0 )); then echo "  - (none)"; else
  for item in "${WARNINGS[@]}"; do echo -e "  ${C_YELLOW}•${C_RESET} ${item}"; done
fi

echo -e "\n${C_RED}${C_BOLD}${E_FAIL} Failed - must fix before upgrading (${#FAILED[@]})${C_RESET}"
if (( ${#FAILED[@]} == 0 )); then echo "  - (none)"; else
  for item in "${FAILED[@]}"; do echo -e "  ${C_RED}•${C_RESET} ${item}"; done
fi

# Final verdict + exit code (0 = ready, 1 = blockers found).
echo -e "\n${C_BOLD}------------------------------------------------------------------${C_RESET}"
if (( ${#FAILED[@]} == 0 )); then
  echo -e "${C_GREEN}${C_BOLD}${E_PASS} RESULT: No blocking issues found. Cluster looks ready for upgrade.${C_RESET}"
  echo    "        Still review the warnings above, read the ${TARGET_VERSION} release notes,"
  echo    "        and test in a non-production cluster first. Upgrades are ONE-WAY."
  FINAL_RC=0
else
  echo -e "${C_RED}${C_BOLD}${E_FAIL} RESULT: ${#FAILED[@]} blocking issue(s) found. Resolve them before upgrading.${C_RESET}"
  FINAL_RC=1
fi
echo -e "${C_BOLD}------------------------------------------------------------------${C_RESET}"

# =============================================================================
# REFERENCES
# -----------------------------------------------------------------------------
# Handy links for planning the upgrade and verifying anything this script flags.
# =============================================================================
echo -e "\n${C_BOLD}📚 ==== References ==== 📚${C_RESET}"
echo "  - Update existing cluster to new Kubernetes version:"
echo "      https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html"
echo "  - Best Practices for Cluster Upgrades:"
echo "      https://docs.aws.amazon.com/eks/latest/best-practices/cluster-upgrades.html"
echo "  - Review release notes for Kubernetes versions on standard support:"
echo "      https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html"
echo "  - IAM role for Standard mode:"
echo "      https://docs.aws.amazon.com/eks/latest/userguide/cluster-iam-role.html"
echo "  - IAM role for Auto mode:"
echo "      https://docs.aws.amazon.com/eks/latest/userguide/auto-cluster-iam-role.html"

exit "${FINAL_RC}"
