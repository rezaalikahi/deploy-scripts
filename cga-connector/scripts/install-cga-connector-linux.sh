#!/usr/bin/env bash
#
# Copyright (c) 2020-present, Barracuda Networks Inc.
#
# Set error handling

set -euo pipefail

# Set help
function program_help {
    echo -e "Install CloudGen Access User Directory Connector script

Available parameters:
  -e \\t\\t- Extra connector environment variables (can be used multiple times)
  -h \\t\\t- Show this help
  -l string \\t- Loglevel (debug, info, warning, error, critical), defaults to info.
  -n \\t\\t- Don't start services after install
  -t token \\t- Specify CloudGen Access Connector enrollment token
  -u \\t\\t- Unattended install, skip requesting input <optional>
  -z \\t\\t- Skip configuring ntp server <optional>
"
    exit 0
}

function validate_connector_token() {
    if [[ "${1}" =~ ^https:\/\/[a-zA-Z0-9.-]+\.(fyde\.com|access\.barracuda\.com)\/connectors/v[0-9]+\/[0-9]+\?auth_token=[0-9a-zA-Z]+\&tenant_id=[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
        return 0
    fi
    return 1
}

function use_authorize_command() {
    local first="${1}"
    local second="1.3.20"
    local x y

    if [[ "${first}" != "0.0.1" ]]; then
        while [[ "${first}" || "${second}" ]]; do
            x=${first%%.*} y=${second%%.*}
            [[ $((10#${x:-0})) -gt $((10#${y:-0})) ]] && return 0 # first is greater
            [[ $((10#${x:-0})) -lt $((10#${y:-0})) ]] && return 1 # second is greater
            first="${first:${#x}+1}"
            second="${second:${#y}+1}"
        done
    fi

    return 0 # versions are equal
}

# Get parameters
EXTRA=()
REPO_URL="downloads.access.barracuda.com"

while getopts ":e:hl:nt:uz" OPTION 2>/dev/null; do
    case "${OPTION}" in
    e)
        VALUE="$(echo "${OPTARG}" | cut -d= -f1 | tr '[:lower:]-' '[:upper:]_')"
        if ! [[ "${VALUE}" =~ ^FYDE_ ]]; then
            VALUE="FYDE_${VALUE}"
        fi
        EXTRA+=("${VALUE}=$(echo "${OPTARG}" | cut -d= -f2-)")
        ;;
    h)
        program_help
        ;;
    l)
        LOGLEVEL="${OPTARG}"
        ;;
    n)
        NO_START_SVC="true"
        ;;
    t)
        CONNECTOR_TOKEN="${OPTARG}"
        if ! validate_connector_token "${CONNECTOR_TOKEN:-}"; then
            echo "CloudGen Access Connector enrollment token is invalid, please try again"
            exit 3
        fi
        ;;
    u)
        UNATTENDED_INSTALL="true"
        ;;
    z)
        SKIP_NTP="true"
        ;;
    \?)
        echo "Invalid option: -${OPTARG}"
        exit 3
        ;;
    :)
        echo "Option -${OPTARG} requires an argument." >&2
        exit 3
        ;;
    *)
        echo "${OPTARG} is an unrecognized option"
        exit 3
        ;;
    esac
done

# Functions
function log_entry() {
    local LOG_TYPE="${1:?Needs log type}"
    local LOG_MSG="${2:?Needs log message}"
    local COLOR='\033[93m'
    local ENDCOLOR='\033[0m'

    echo -e "${COLOR}$(date "+%Y-%m-%d %H:%M:%S") [$LOG_TYPE] ${LOG_MSG}${ENDCOLOR}"
}

function clear_tmp() {
    local CLEAR_PATH="${1:?"Needs path to remove"}"
    local COUNT

    log_entry "INFO" "Clearing temporary folder(s)"
    COUNT="$(rm -rfv "${CLEAR_PATH}" | wc -l)"
    log_entry "INFO" "Removed ${COUNT} item(s)"
}

# Check if run as root
if [[ "${EUID}" != "0" ]]; then
    log_entry "ERROR" "This script needs to be run as root"
    exit 1
fi

# Prepare inputs
if [[ "${UNATTENDED_INSTALL:-}" == "true" ]] || ! [[ -t 0 ]]; then
    if [[ -z "${CONNECTOR_TOKEN:-}" ]]; then
        log_entry "INFO" "Connector Token not found on command line, make sure you provide it some other way"
    fi
else
    if [[ -z "${CONNECTOR_TOKEN:-}" ]]; then
        log_entry "INFO" "Please provide required variables"

        while [[ -z "${CONNECTOR_TOKEN:-}" ]]; do
            read -r -p "Paste the CloudGen Access Connector enrollment token: " CONNECTOR_TOKEN
            echo ""
            if [[ -z "${CONNECTOR_TOKEN:-}" ]]; then
                log_entry "ERROR" "CloudGen Access Connector enrollment token cannot be empty"
            elif ! validate_connector_token "${CONNECTOR_TOKEN:-}"; then
                log_entry "ERROR" "CloudGen Access Connector enrollment token is invalid, please try again"
                unset CONNECTOR_TOKEN
            fi
        done
    fi

    if [[ -z "${EXTRA:-}" ]]; then
        read -r -p "Extra Connector Parameters (KEY=VALUE) (Enter an empty line to continue): " KV

        while [[ -n "${KV:-}" ]]; do
            VALUE="$(echo "${KV}" | cut -d= -f1 | tr '[:lower:]-' '[:upper:]_')"
            if ! [[ "${VALUE}" =~ ^FYDE_ ]]; then
                VALUE="FYDE_${VALUE}"
            fi
            EXTRA+=("${VALUE}=$(echo "${KV}" | cut -d= -f2-)")
            read -r -p "Extra Connector Parameters (KEY=VALUE) (Enter an empty line to continue): " KV
        done
    fi
fi

# Pre-requisites

# shellcheck disable=SC1091
source /etc/os-release

log_entry "INFO" "Check for package manager lock file"
for i in $(seq 1 300); do
    if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
        if ! fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; then
            break
        fi
    elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
        if ! [ -f /var/run/yum.pid ]; then
            break
        fi
    else
        echo "Unrecognized distribution type: ${ID_LIKE}"
        exit 4
    fi
    echo "Lock found. Check ${i}/300"
    sleep 1
done

if [[ "${ID_LIKE:-}" =~ rhel ]]; then
    log_entry "INFO" "Install pre-requisites"
    yum -y install yum-utils
fi

if [[ "${SKIP_NTP:-}" == "true" ]]; then
    log_entry "INFO" "Skipping NTP configuration"
else
    if [[ "${ID_LIKE:-}" =~ rhel ]]; then
        log_entry "INFO" "Ensure chrony daemon is enabled on system boot and started"
        yum -y install chrony
        systemctl enable chronyd
        systemctl start chronyd
    fi

    log_entry "INFO" "Ensure time synchronization is enabled"
    timedatectl set-ntp off
    timedatectl set-ntp on
fi

log_entry "INFO" "Add Fyde repository"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    wget -q -O - "https://${REPO_URL}/fyde-public-key.asc" | apt-key add -
    bash -c "cat > /etc/apt/sources.list.d/fyde.list <<EOF
deb https://${REPO_URL}/apt stable main
EOF"
    sudo apt update
elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
    # Quick hack for "Error: GPG check FAILED"
    # The signature will be updated for next releases
    export OPENSSL_ENABLE_SHA1_SIGNATURES=1
    yum-config-manager -y --add-repo "https://${REPO_URL}/fyde.repo"
fi

log_entry "INFO" "Install CloudGen Access Connector"
if [[ "${ID_LIKE:-}${ID}" =~ debian ]]; then
    apt -y install fyde-connector
elif [[ "${ID_LIKE:-}" =~ rhel ]]; then
    yum -y install fyde-connector
fi
systemctl enable fyde-connector

CONNECTOR_VERSION="$(/usr/bin/fyde-connector --version)"
log_entry "INFO" "Installed version is ${CONNECTOR_VERSION}"

log_entry "INFO" "Configure CloudGen Access Connector"

UNIT_OVERRIDE=("[Service]" "Environment='FYDE_LOGLEVEL=${LOGLEVEL:-"info"}'")

if ! [[ "${UNATTENDED_INSTALL:-}" == "true" ]]; then
    UNIT_OVERRIDE+=("Environment='FYDE_ENROLLMENT_TOKEN=${CONNECTOR_TOKEN}'")

    # Support bash<4.4
    # shellcheck disable=SC2199
    if ! [[ "${EXTRA[@]+"${EXTRA[@]}"}" =~ AUTH_TOKEN ]] && ! [[ "${EXTRA[@]+"${EXTRA[@]}"}" =~ LDAP_ ]]; then
        TMPFILE="$(mktemp --tmpdir fyde-connector.XXXXXXX)"
        trap 'clear_tmp ${TMPFILE}' EXIT

        CONNECTOR_COMMAND_ARGS=(authorize)

        # Check for older authentication process
        if ! use_authorize_command "${CONNECTOR_VERSION}"; then
            CONNECTOR_COMMAND_ARGS=(--dry-run --run-once)
        fi

        if /usr/bin/fyde-connector "--enrollment-token=${CONNECTOR_TOKEN}" "${CONNECTOR_COMMAND_ARGS[@]}" 2>&1 | tee "${TMPFILE}"; then
            # Success
            if grep -q 'Authorization was successful' "${TMPFILE}"; then
                echo "continue and do nothing" >/dev/null
            elif grep -q 'Your Azure Authentication token is:' "${TMPFILE}"; then
                AZURE_AUTH_TOKEN=$(grep -E -o 'Your Azure Authentication token is:.+' "${TMPFILE}" | cut -d: -f2-)
                UNIT_OVERRIDE+=("Environment='FYDE_AZURE_AUTH_TOKEN=${AZURE_AUTH_TOKEN}'")
            elif grep -q 'Your Google Suite token is:' "${TMPFILE}"; then
                GOOGLE_AUTH_TOKEN=$(grep -E -o 'Your Google Suite token is:.+' "${TMPFILE}" | cut -d: -f2-)
                UNIT_OVERRIDE+=("Environment='FYDE_GOOGLE_AUTH_TOKEN=${GOOGLE_AUTH_TOKEN}'")
            else
                log_entry "ERROR" "Something failed. Check the log above."
                exit 2
            fi
        else
            # Error
            if grep -q 'ldap_.* not set' "${TMPFILE}"; then
                log_entry "ERROR" "Missing parameters for ldap directory. Check the documentation for required ldap arguments and specify as extra connector parameters."
            elif grep -q 'APIFailException.*422' "${TMPFILE}"; then
                log_entry "ERROR" "Invalid auth token. Confirm and run the script again."
            elif grep -q 'okta-auth-token and okta-domainname variables are both mandatory' "${TMPFILE}"; then
                log_entry "ERROR" "okta-auth-token and okta-domainname variables are both mandatory"
            else
                log_entry "ERROR" "Something failed. Ensure the parameters are correct and run the script again."
            fi
            exit 2
        fi

    elif [[ "${EXTRA[@]+"${EXTRA[@]}"}" =~ OKTA_AUTH_TOKEN ]] && ! [[ "${EXTRA[@]+"${EXTRA[@]}"}" =~ OKTA_DOMAINNAME ]]; then
        log_entry "ERROR" "okta-auth-token and okta-domainname variables are both mandatory"
        exit 2
    fi
fi

mkdir -p /etc/systemd/system/fyde-connector.service.d
printf "%s\n" "${UNIT_OVERRIDE[@]}" >/etc/systemd/system/fyde-connector.service.d/10-environment.conf
if [[ "${#EXTRA[@]}" -gt 0 ]]; then
    printf "Environment='%s'\n" "${EXTRA[@]}" >>/etc/systemd/system/fyde-connector.service.d/10-environment.conf
fi
chmod 600 /etc/systemd/system/fyde-connector.service.d/10-environment.conf

systemctl --system daemon-reload

if [[ "${NO_START_SVC:-}" == "true" ]]; then
    log_entry "INFO" "Skip CloudGen Access Connector daemon start"
    systemctl stop fyde-connector
    log_entry "INFO" "To start service:"
    echo "systemctl start fyde-connector"
else
    log_entry "INFO" "Ensure CloudGen Access Connector daemon is running with latest config"
    systemctl restart fyde-connector
fi

log_entry "INFO" "To check logs:"
echo "journalctl -u fyde-connector -f"

log_entry "INFO" "Complete."
