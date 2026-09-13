#!/usr/bin/env bash
# Shared deployment configuration loader for TAX.
#
# Contract variables (see docs/LOCAL_CONFIGURATION.md and deploy.env.example):
#   TAX_DEPLOY_HOST            SSH destination ("user@host")
#   TAX_DEPLOY_USER            service user running the systemd unit
#   TAX_DEPLOY_GROUP           service group running the systemd unit
#   TAX_DEPLOY_PROJECT_DIR     absolute path to the TAX checkout on the server
#   TAX_DEPLOY_DOMAIN          public domain terminating TLS
#   TAX_DEPLOY_PORT            loopback port (systemd, Caddy and health check)
#   TAX_DEPLOY_DB_PATH         absolute path to the SQLite database file
#   TAX_DEPLOY_APNS_KEY_PATH   absolute path to the APNs signing key (.p8)
#   TAX_DEPLOY_ENV_FILE        absolute path to the backend environment file
#
# Precedence: explicit environment variables, then the file named by
# TAX_DEPLOY_CONFIG, then ~/.config/tax/deploy.env. A file named by
# TAX_DEPLOY_CONFIG that does not exist is an error. Missing or invalid
# values are reported before any SSH connection, Git operation, sudo call,
# file change or service command.
#
# Usage in scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/deploy-config.sh"
#   tax_deploy_config_load || exit 1
#
# Direct commands (no SSH, systemd, Caddy or system files are touched):
#   deploy-config.sh check        validate the configuration and summarize it
#   deploy-config.sh render DIR   render tax.service and Caddyfile into DIR
#
# TAX_DEPLOY_TEMPLATE_DIR overrides the directory the render command reads
# tax.service and Caddyfile from (used by tests).

TAX_DEPLOY_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep this list in sync with deploy.env.example and docs/LOCAL_CONFIGURATION.md.
TAX_DEPLOY_CONTRACT_VARS="TAX_DEPLOY_HOST TAX_DEPLOY_USER TAX_DEPLOY_GROUP TAX_DEPLOY_PROJECT_DIR TAX_DEPLOY_DOMAIN TAX_DEPLOY_PORT TAX_DEPLOY_DB_PATH TAX_DEPLOY_APNS_KEY_PATH TAX_DEPLOY_ENV_FILE"

tax_deploy_die() {
    printf 'deploy-config: %s\n' "$*" >&2
    return 1
}

tax_deploy_config_file() {
    # Print the private configuration file to read, or return non-zero when
    # no configuration file can be found.
    if [[ -n "${TAX_DEPLOY_CONFIG:-}" ]]; then
        if [[ ! -f $TAX_DEPLOY_CONFIG ]]; then
            tax_deploy_die "TAX_DEPLOY_CONFIG is set but not a readable file: $TAX_DEPLOY_CONFIG"
            return 1
        fi
        printf '%s\n' "$TAX_DEPLOY_CONFIG"
        return 0
    fi
    if [[ -n "${HOME:-}" && -f "$HOME/.config/tax/deploy.env" ]]; then
        printf '%s\n' "$HOME/.config/tax/deploy.env"
        return 0
    fi
    return 1
}

tax_deploy_validate_port() {
    local value=$1
    if [[ -z $value || $value == *[!0-9]* ]]; then
        tax_deploy_die "TAX_DEPLOY_PORT must be an integer between 1 and 65535, got '$value'"
        return 1
    fi
    value=$((10#$value))
    if ((value < 1 || value > 65535)); then
        tax_deploy_die "TAX_DEPLOY_PORT must be an integer between 1 and 65535, got '$1'"
        return 1
    fi
    return 0
}

tax_deploy_validate_domain() {
    local value=$1
    local pattern='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$'
    if [[ -z $value || ! $value =~ $pattern ]]; then
        tax_deploy_die "TAX_DEPLOY_DOMAIN must be a hostname such as tax.example.com, got '$value'"
        return 1
    fi
    return 0
}

tax_deploy_validate_name() {
    local var_name=$1 value=$2
    local pattern='^[a-z_][a-z0-9_-]{0,31}$'
    if [[ -z $value || ! $value =~ $pattern ]]; then
        tax_deploy_die "$var_name must be a POSIX user/group name (lowercase letters, digits, '_' or '-', at most 32 characters), got '$value'"
        return 1
    fi
    return 0
}

tax_deploy_validate_host() {
    local value=$1
    local pattern='^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$'
    if [[ -z $value || ! $value =~ $pattern ]]; then
        tax_deploy_die "TAX_DEPLOY_HOST must be an SSH destination in the form 'user@host', got '$value'"
        return 1
    fi
    return 0
}

tax_deploy_validate_path() {
    local var_name=$1 value=$2
    # Absolute path with a conservative character allowlist so the value is
    # safe to embed in systemd units, shell command strings and diagnostics.
    local pattern='/[-0-9A-Za-z._/]+'
    if [[ $value != /* || ! $value =~ $pattern ]]; then
        tax_deploy_die "$var_name must be an absolute path using only '/', letters, digits, '.', '_' and '-', got '$value'"
        return 1
    fi
    return 0
}

tax_deploy_config_validate() {
    local var
    for var in $TAX_DEPLOY_CONTRACT_VARS; do
        if [[ -z "${!var:-}" ]]; then
            printf 'deploy-config: required deployment value %s is missing\n' "$var" >&2
            printf 'deploy-config: set it via the environment or the private configuration file (see docs/LOCAL_CONFIGURATION.md)\n' >&2
            return 1
        fi
    done

    tax_deploy_validate_host "$TAX_DEPLOY_HOST" || return 1
    tax_deploy_validate_name TAX_DEPLOY_USER "$TAX_DEPLOY_USER" || return 1
    tax_deploy_validate_name TAX_DEPLOY_GROUP "$TAX_DEPLOY_GROUP" || return 1
    tax_deploy_validate_domain "$TAX_DEPLOY_DOMAIN" || return 1
    tax_deploy_validate_port "$TAX_DEPLOY_PORT" || return 1
    for var in TAX_DEPLOY_PROJECT_DIR TAX_DEPLOY_DB_PATH TAX_DEPLOY_APNS_KEY_PATH TAX_DEPLOY_ENV_FILE; do
        tax_deploy_validate_path "$var" "${!var}" || return 1
    done

    # Derived locations shared by the rendered templates and deploy.sh.
    TAX_DEPLOY_SERVER_DIR="${TAX_DEPLOY_PROJECT_DIR%/}/server"
    TAX_DEPLOY_VENV_DIR="$TAX_DEPLOY_SERVER_DIR/venv"
    TAX_DEPLOY_DATA_DIR="${TAX_DEPLOY_DB_PATH%/*}"
    TAX_DEPLOY_KEYS_DIR="${TAX_DEPLOY_APNS_KEY_PATH%/*}"
    if [[ -z $TAX_DEPLOY_DATA_DIR || -z $TAX_DEPLOY_KEYS_DIR ]]; then
        tax_deploy_die "TAX_DEPLOY_DB_PATH and TAX_DEPLOY_APNS_KEY_PATH must include a directory component"
        return 1
    fi
    return 0
}

tax_deploy_config_read() {
    # Parse the configuration file as a strict KEY=VALUE format. The file is
    # never evaluated by the shell: values with quotes or shell
    # metacharacters are rejected instead of executed or interpolated.
    local file=$1 line key value var
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            '' | '#'*)
                continue
                ;;
            [A-Za-z_]*=*)
                ;;
            *)
                tax_deploy_die "invalid line in $file (expected KEY=VALUE): $line"
                return 1
                ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case $key in
            *[!A-Za-z0-9_]*)
                tax_deploy_die "invalid variable name in $file: $key"
                return 1
                ;;
        esac
        # Strip one pair of matching surrounding quotes, if present.
        case $value in
            \"*\")
                value=${value#\"}
                value=${value%\"}
                ;;
            \'*\')
                value=${value\'}
                value=${value%\'}
                ;;
        esac
        case $value in
            *[!0-9A-Za-z_@%+=:,./-]*)
                tax_deploy_die "value for $key in $file contains unsupported characters"
                return 1
                ;;
        esac
        # Only contract variables are assigned; unrelated keys (for example
        # Compose-only settings) are kept out of the environment.
        for var in $TAX_DEPLOY_CONTRACT_VARS; do
            if [[ $key == "$var" ]]; then
                printf -v "$var" '%s' "$value"
            fi
        done
    done <"$file"
}

tax_deploy_config_load() {
    # Resolve the deployment configuration and validate it. Never talks to
    # the network, runs service commands or modifies files.
    local var file i
    local -a env_names=()
    local -a env_values=()

    # 1. Explicit environment variables win over every file.
    for var in $TAX_DEPLOY_CONTRACT_VARS; do
        if [[ -n "${!var:-}" ]]; then
            env_names+=("$var")
            env_values+=("${!var}")
        fi
    done

    # 2. Fill the remaining variables from the private configuration file.
    if file="$(tax_deploy_config_file)"; then
        if ! tax_deploy_config_read "$file"; then
            tax_deploy_die "failed to read deployment configuration file: $file"
            return 1
        fi
    fi

    # 3. Restore environment-provided values so the file cannot override them.
    if [[ ${#env_names[@]} -gt 0 ]]; then
        for i in "${!env_names[@]}"; do
            printf -v "${env_names[$i]}" '%s' "${env_values[$i]}"
        done
    fi

    tax_deploy_config_validate
}

tax_deploy_sh_quote() {
    # Quote a value for safe use inside a POSIX shell command string.
    local value=$1
    case $value in
        # Safe to use unquoted.
        *[!A-Za-z0-9_@%+=:,./-]* | '') ;;
        *)
            printf '%s' "$value"
            return 0
            ;;
    esac
    local quoted="'" i ch
    for ((i = 0; i < ${#value}; i++)); do
        ch=${value:$i:1}
        if [[ $ch == "'" ]]; then
            quoted="$quoted'\\''"
        else
            quoted="$quoted$ch"
        fi
    done
    printf '%s' "$quoted'"
}

tax_deploy_render_file() {
    local src=$1 dst=$2 line var value content="" leftovers

    while IFS= read -r line || [[ -n $line ]]; do
        content="$content$line"$'\n'
    done <"$src"

    for var in $TAX_DEPLOY_CONTRACT_VARS TAX_DEPLOY_SERVER_DIR TAX_DEPLOY_VENV_DIR TAX_DEPLOY_DATA_DIR TAX_DEPLOY_KEYS_DIR; do
        value=${!var}
        content="${content//@$var@/$value}"
    done

    leftovers="$(printf '%s' "$content" | { grep -oE '@TAX_DEPLOY_[A-Za-z0-9_]+@' || true; } | sort -u)"
    if [[ -n $leftovers ]]; then
        tax_deploy_die "refusing to write $dst: unrendered placeholder(s) remain: $(printf '%s' "$leftovers" | tr '\n' ' ')"
        return 1
    fi

    printf '%s' "$content" >"$dst"
}

tax_deploy_render_templates() {
    # Render server/tax.service and Caddyfile into TARGET_DIR. Only writes
    # inside TARGET_DIR and refuses output that still contains placeholders,
    # so an unrendered template can never be installed by accident.
    local target_dir=$1
    local template_dir="${TAX_DEPLOY_TEMPLATE_DIR:-}"
    local unit_src caddy_src

    if [[ -n $template_dir ]]; then
        unit_src="$template_dir/tax.service"
        caddy_src="$template_dir/Caddyfile"
    else
        unit_src="$TAX_DEPLOY_REPO_ROOT/server/tax.service"
        caddy_src="$TAX_DEPLOY_REPO_ROOT/Caddyfile"
    fi

    if [[ ! -f $unit_src ]]; then
        tax_deploy_die "systemd unit template not found: $unit_src"
        return 1
    fi
    if [[ ! -f $caddy_src ]]; then
        tax_deploy_die "Caddyfile template not found: $caddy_src"
        return 1
    fi

    tax_deploy_render_file "$unit_src" "$target_dir/tax.service" || return 1
    tax_deploy_render_file "$caddy_src" "$target_dir/Caddyfile" || return 1
    return 0
}

tax_deploy_usage() {
    cat <<'EOF'
Usage: deploy-config.sh check
       deploy-config.sh render TARGET_DIR

  check        Load and validate the private deployment configuration.
  render DIR   Render server/tax.service and Caddyfile into DIR using the
               validated configuration. Touches no SSH, systemd, Caddy or
               system files.
EOF
}

tax_deploy_main() {
    local command="${1:-}"
    case $command in
        check)
            tax_deploy_config_load || exit 1
            printf 'TAX deployment configuration is valid.\n'
            printf '  domain: %s\n' "$TAX_DEPLOY_DOMAIN"
            printf '  loopback port: %s\n' "$TAX_DEPLOY_PORT"
            printf '  project dir: %s\n' "$TAX_DEPLOY_PROJECT_DIR"
            ;;
        render)
            if [[ $# -lt 2 ]]; then
                tax_deploy_usage >&2
                exit 2
            fi
            if [[ ! -d $2 ]]; then
                tax_deploy_die "render target is not a directory: $2"
                exit 1
            fi
            tax_deploy_config_load || exit 1
            tax_deploy_render_templates "$2" || exit 1
            printf 'Rendered tax.service and Caddyfile into %s\n' "$2"
            ;;
        *)
            tax_deploy_usage >&2
            exit 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    tax_deploy_main "$@"
fi
