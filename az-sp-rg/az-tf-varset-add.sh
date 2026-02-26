#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# This script:
#  1) Takes: <project_name> <workspace_name> <azure_service_principal_display_name>
#  2) Appends existing varset "Azure-Tenant-ID-OIDC" to the Terraform project scope (no removal)
#     - prints current project associations before + after
#  3) Detects default Azure subscription name and appends the matching existing varset
#     to the Terraform workspace scope (no removal)
#     - "IT Non-Production" -> "IT-Non-Production-Subscription-ID"
#     - "IT Production"     -> "IT-Production-Subscription-ID"
#     - prints current workspace associations before + after
#  4) Creates/updates a Terraform workspace variable:
#       key         = "IT-Production-Subscription-ID"
#       value       = Azure SP clientId/appId
#       category    = "terraform"
#       sensitive   = true
#       description = SP display name
#
# Requirements:
#  - bash, curl, jq, az, python3
#  - Azure CLI logged in and able to query subscription and service principal:
#      az login
#      az account show
#      az ad sp list --display-name ...
#
# Required env vars:
#  - TF_CLOUD_ORGANIZATION
#
# Usage:
#  ./tfc_varset_scope.sh "<project_name>" "<workspace_name>" "<sp_display_name>"
# ------------------------------------------------------------

PROJECT_NAME="${1:-}"
WORKSPACE_NAME="${2:-}"
SP_NAME="${3:-}"

if [[ -z "${PROJECT_NAME}" || -z "${WORKSPACE_NAME}" || -z "${SP_NAME}" ]]; then
  echo ""
  echo "------------------------------------------------------------"
  echo "This script:"
  echo "  1) Takes: <project_name> <workspace_name> <azure_service_principal_display_name>"
  echo "  2) Appends existing varset 'Azure-Tenant-ID-OIDC' to the Terraform project scope (no removal)"
  echo "     - prints current project associations before + after"
  echo "  3) Detects default Azure subscription name and appends the matching existing varset"
  echo "     to the Terraform workspace scope (no removal)"
  echo "     - 'IT Non-Production' -> 'IT-Non-Production-Subscription-ID'"
  echo "     - 'IT Production'     -> 'IT-Production-Subscription-ID'"
  echo "     - prints current workspace associations before + after"
  echo "  4) Creates/updates a Terraform workspace variable:"
  echo "       key         = 'IT-Production-Subscription-ID'"
  echo "       value       = Azure SP clientId/appId"
  echo "       category    = 'terraform'"
  echo "       sensitive   = true"
  echo "       description = SP display name"
  echo ""
  echo "Requirements:"
  echo "  - bash, curl, jq, az, python3"
  echo "  - Azure CLI logged in and able to query subscription and service principal:"
  echo "      az login"
  echo "      az account show"
  echo "      az ad sp list --display-name ..."
  echo ""
  echo "Required env vars:"
  echo "  - TF_CLOUD_ORGANIZATION"
  echo ""
  echo "Usage:"
  echo "  $0 \"<project_name>\" \"<workspace_name>\" \"<sp_display_name>\""
  echo "------------------------------------------------------------"
  exit 2
fi

: "${TF_CLOUD_ORGANIZATION:?Environment variable TF_CLOUD_ORGANIZATION must be set}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required software: $1" >&2; exit 3; }; }
need_cmd curl
need_cmd jq
need_cmd az
need_cmd python3


if [[ -f "${HOME}/.terraform.d/credentials.tfrc.json" ]]; then
  TF_API_TOKEN=$(jq -r '.credentials["app.terraform.io"].token // empty' "${HOME}/.terraform.d/credentials.tfrc.json")
else
  echo "ERROR: Terraform credentials file not found." >&2
  exit 1
fi

if [[ -z "${TF_API_TOKEN}" ]]; then
  echo "ERROR: Terraform Cloud token not found in credentials file." >&2
  exit 2
fi

echo "Using Terraform Cloud API token: ${TF_API_TOKEN:0:4}... (length: ${#TF_API_TOKEN})"
AUTH_HEADER="Authorization: Bearer ${TF_API_TOKEN}"

TFC_ADDR="https://app.terraform.io/api/v2"
AUTH_HEADER="Authorization: Bearer ${TF_API_TOKEN}"
CT_HEADER="Content-Type: application/vnd.api+json"


urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

api_get() {
  local url="$1"
  curl -sS -H "${AUTH_HEADER}" -H "${CT_HEADER}" "${url}"
}

api_post_capture() {
  local url="$1"
  local data="$2"
  local out_file="$3"
  curl -sS -o "${out_file}" -w "%{http_code}" \
    -H "${AUTH_HEADER}" -H "${CT_HEADER}" \
    -X POST \
    --data "${data}" \
    "${url}"
}

api_patch_capture() {
  local url="$1"
  local data="$2"
  local out_file="$3"
  curl -sS -o "${out_file}" -w "%{http_code}" \
    -H "${AUTH_HEADER}" -H "${CT_HEADER}" \
    -X PATCH \
    --data "${data}" \
    "${url}"
}

# ---------- Look up Project ID by name ----------
get_project_id_by_name() {
  local name="$1"
  local page=1
  local page_size=100

  while :; do
    local json
    json="$(api_get "${TFC_ADDR}/organizations/${TF_CLOUD_ORGANIZATION}/projects?page%5Bnumber%5D=${page}&page%5Bsize%5D=${page_size}")"
    local id
    id="$(echo "${json}" | jq -r --arg n "${name}" '.data[]? | select(.attributes.name==$n) | .id' | head -n1)"
    if [[ -n "${id}" && "${id}" != "null" ]]; then
      echo "${id}"
      return 0
    fi

    # Stop if no next page
    local has_next
    has_next="$(echo "${json}" | jq -r '.links.next? // empty')"
    if [[ -z "${has_next}" ]]; then
      break
    fi
    page=$((page + 1))
  done

  return 1
}

# ---------- Look up Workspace ID by name ----------
get_workspace_id_by_name() {
  local name="$1"
  local json
  json="$(api_get "${TFC_ADDR}/organizations/${TF_CLOUD_ORGANIZATION}/workspaces/${name}")"
  echo "${json}" | jq -r '.data.id'
}

# ---------- Find variable set id by name ----------
get_varset_id_by_name() {
  local varset_name="$1"
  local q
  q="$(urlencode "${varset_name}")"
  local json
  json="$(api_get "${TFC_ADDR}/organizations/${TF_CLOUD_ORGANIZATION}/varsets?q=${q}&page%5Bsize%5D=100")"
  echo "${json}" | jq -r --arg n "${varset_name}" '.data[]? | select(.attributes.name==$n) | .id' | head -n1
}

# ---------- List varset relationships ----------
list_varset_projects() {
  local varset_id="$1"
  api_get "${TFC_ADDR}/varsets/${varset_id}/relationships/projects"
}

list_varset_workspaces() {
  local varset_id="$1"
  api_get "${TFC_ADDR}/varsets/${varset_id}/relationships/workspaces"
}

print_varset_projects() {
  local varset_id="$1"
  echo "Existing PROJECT associations for varset ${varset_id}:"
  list_varset_projects "${varset_id}" | jq -r '.data[]? | "  - \(.id)"' || true
}

print_varset_workspaces() {
  local varset_id="$1"
  echo "Existing WORKSPACE associations for varset ${varset_id}:"
  list_varset_workspaces "${varset_id}" | jq -r '.data[]? | "  - \(.id)"' || true
}

varset_has_project() {
  local varset_id="$1"
  local project_id="$2"
  list_varset_projects "${varset_id}" | jq -e --arg pid "${project_id}" '.data[]? | select(.id==$pid)' >/dev/null
}

varset_has_workspace() {
  local varset_id="$1"
  local workspace_id="$2"
  list_varset_workspaces "${varset_id}" | jq -e --arg wid "${workspace_id}" '.data[]? | select(.id==$wid)' >/dev/null
}

# ---------- Append (add) project/workspace to varset scope IF missing ----------
attach_varset_to_project_safe() {
  local varset_id="$1"
  local project_id="$2"

  print_varset_projects "${varset_id}"

  if varset_has_project "${varset_id}" "${project_id}"; then
    echo "Project ${project_id} already in scope for varset ${varset_id}; skipping."
    return 0
  fi

  echo "Appending project ${project_id} to varset ${varset_id}..."
  local payload out code
  payload="$(jq -n --arg pid "${project_id}" '{data:[{type:"projects",id:$pid}]}' )"
  out="/tmp/tfc_post_projects.$$"
  code="$(api_post_capture "${TFC_ADDR}/varsets/${varset_id}/relationships/projects" "${payload}" "${out}")"

  if [[ "${code}" != "204" ]]; then
    echo "ERROR: Failed to append project to varset. HTTP ${code}" >&2
    jq . "${out}" >&2 || cat "${out}" >&2
    rm -f "${out}"
    exit 30
  fi
  rm -f "${out}"

  echo "Appended successfully."
  print_varset_projects "${varset_id}"
}

attach_varset_to_workspace_safe() {
  local varset_id="$1"
  local workspace_id="$2"

  print_varset_workspaces "${varset_id}"

  if varset_has_workspace "${varset_id}" "${workspace_id}"; then
    echo "Workspace ${workspace_id} already in scope for varset ${varset_id}; skipping."
    return 0
  fi

  echo "Appending workspace ${workspace_id} to varset ${varset_id}..."
  local payload out code
  payload="$(jq -n --arg wid "${workspace_id}" '{data:[{type:"workspaces",id:$wid}]}' )"
  out="/tmp/tfc_post_workspaces.$$"
  code="$(api_post_capture "${TFC_ADDR}/varsets/${varset_id}/relationships/workspaces" "${payload}" "${out}")"

  if [[ "${code}" != "204" ]]; then
    echo "ERROR: Failed to append workspace to varset. HTTP ${code}" >&2
    jq . "${out}" >&2 || cat "${out}" >&2
    rm -f "${out}"
    exit 31
  fi
  rm -f "${out}"

  echo "Appended successfully."
  print_varset_workspaces "${varset_id}"
}

# ---------- Create or update workspace variable ----------
upsert_workspace_var() {
  local workspace_id="$1"
  local key="$2"
  local value="$3"
  local description="$4"
  local category="$5"     # terraform | env
  local sensitive="$6"    # true | false

  echo "Listing existing workspace variables..."
  local vars_json
  vars_json="$(api_get "${TFC_ADDR}/workspaces/${workspace_id}/vars")"

  local existing_id
  existing_id="$(echo "${vars_json}" | jq -r --arg k "${key}" '.data[]? | select(.attributes.key==$k) | .id' | head -n1)"

  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    echo "Variable '${key}' exists (id: ${existing_id}). Updating..."
    local payload out code
    payload="$(jq -n \
      --arg id "${existing_id}" \
      --arg key "${key}" \
      --arg value "${value}" \
      --arg desc "${description}" \
      --arg cat "${category}" \
      --argjson sens "$( [[ "${sensitive}" == "true" ]] && echo true || echo false )" \
      '{
        data:{
          id:$id,
          type:"vars",
          attributes:{
            key:$key,
            value:$value,
            description:$desc,
            category:$cat,
            hcl:false,
            sensitive:$sens
          }
        }
      }')"

    out="/tmp/tfc_patch_var.$$"
    code="$(api_patch_capture "${TFC_ADDR}/workspaces/${workspace_id}/vars/${existing_id}" "${payload}" "${out}")"
    if [[ "${code}" != "200" ]]; then
      echo "ERROR: Failed updating variable. HTTP ${code}" >&2
      jq . "${out}" >&2 || cat "${out}" >&2
      rm -f "${out}"
      exit 40
    fi
    rm -f "${out}"
    echo "Updated '${key}'."
  else
    echo "Variable '${key}' does not exist. Creating..."
    local payload out code
    payload="$(jq -n \
      --arg key "${key}" \
      --arg value "${value}" \
      --arg desc "${description}" \
      --arg cat "${category}" \
      --argjson sens "$( [[ "${sensitive}" == "true" ]] && echo true || echo false )" \
      '{
        data:{
          type:"vars",
          attributes:{
            key:$key,
            value:$value,
            description:$desc,
            category:$cat,
            hcl:false,
            sensitive:$sens
          }
        }
      }')"

    out="/tmp/tfc_post_var.$$"
    code="$(api_post_capture "${TFC_ADDR}/workspaces/${workspace_id}/vars" "${payload}" "${out}")"
    if [[ "${code}" != "201" && "${code}" != "200" ]]; then
      echo "ERROR: Failed creating variable. HTTP ${code}" >&2
      jq . "${out}" >&2 || cat "${out}" >&2
      rm -f "${out}"
      exit 41
    fi
    rm -f "${out}"
    echo "Created '${key}'."
  fi
}

# -------------------- MAIN --------------------

echo "Resolving project '${PROJECT_NAME}' in org '${TF_CLOUD_ORGANIZATION}'..."
PROJECT_ID="$(get_project_id_by_name "${PROJECT_NAME}" || true)"
if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
  echo "ERROR: Project not found: ${PROJECT_NAME}" >&2
  exit 4
fi
echo "  project_id: ${PROJECT_ID}"

echo "Resolving workspace '${WORKSPACE_NAME}' in org '${TF_CLOUD_ORGANIZATION}'..."
WORKSPACE_ID="$(get_workspace_id_by_name "${WORKSPACE_NAME}")"
if [[ -z "${WORKSPACE_ID}" || "${WORKSPACE_ID}" == "null" ]]; then
  echo "ERROR: Workspace not found: ${WORKSPACE_NAME}" >&2
  exit 5
fi
echo "  workspace_id: ${WORKSPACE_ID}"

# 1) Append base varset to PROJECT
BASE_VARSET_NAME="varset-Azure-Tenant-ID-OIDC"
echo "Resolving varset '${BASE_VARSET_NAME}'..."
BASE_VARSET_ID="$(get_varset_id_by_name "${BASE_VARSET_NAME}")"
if [[ -z "${BASE_VARSET_ID}" || "${BASE_VARSET_ID}" == "null" ]]; then
  echo "ERROR: Variable set not found: ${BASE_VARSET_NAME}" >&2
  exit 8
fi
echo "  varset_id: ${BASE_VARSET_ID}"
attach_varset_to_project_safe "${BASE_VARSET_ID}" "${PROJECT_ID}"


# 2) Determine default Azure subscription name, append matching varset to WORKSPACE
AZ_SUB_NAME="$(az account show --query name -o tsv)"
if [[ -z "${AZ_SUB_NAME}" ]]; then
  echo "ERROR: Could not determine default Azure subscription name. Run: az login" >&2
  exit 9
fi
echo "Default Azure subscription: ${AZ_SUB_NAME}"

case "${AZ_SUB_NAME}" in
  "IT Non-Production")
    SUB_VARSET_NAME="varset-IT-Non-Production-Subscription-ID"
    ;;
  "IT Production")
    SUB_VARSET_NAME="varset-IT-Production-Subscription-ID"
    ;;
  *)
    echo "ERROR: Unsupported subscription name '${AZ_SUB_NAME}'. Expected 'IT Non-Production' or 'IT Production'." >&2
    exit 10
    ;;
esac

echo "Resolving varset '${SUB_VARSET_NAME}'..."
SUB_VARSET_ID="$(get_varset_id_by_name "${SUB_VARSET_NAME}")"
if [[ -z "${SUB_VARSET_ID}" || "${SUB_VARSET_ID}" == "null" ]]; then
  echo "ERROR: Variable set not found: ${SUB_VARSET_NAME}" >&2
  exit 11
fi
echo "  varset_id: ${SUB_VARSET_ID}"
attach_varset_to_workspace_safe "${SUB_VARSET_ID}" "${WORKSPACE_ID}"

# 3) Create/update workspace Terraform variable:
#    key: IT-Production-Subscription-ID
#    value: SP clientId/appId
#    description: SP name
VAR_KEY="TFC_AZURE_RUN_CLIENT_ID"

echo "Looking up Azure service principal appId/clientId by display name: '${SP_NAME}'"
SP_APP_ID="$(az ad sp list --display-name "${SP_NAME}" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [[ -z "${SP_APP_ID}" ]]; then
  echo "ERROR: Could not find service principal by display name '${SP_NAME}'" >&2
  echo "Tip: verify with: az ad sp list --display-name \"${SP_NAME}\" -o table" >&2
  exit 12
fi
echo "  clientId/appId: ${SP_APP_ID}"

echo "Upserting workspace variable '${VAR_KEY}' (category=terraform, sensitive=true, description='${SP_NAME}')..."
upsert_workspace_var "${WORKSPACE_ID}" "${VAR_KEY}" "${SP_APP_ID}" "${SP_NAME}" "terraform" "true"

echo "Done."