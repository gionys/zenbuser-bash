#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"

# ── helpers ──────────────────────────────────────────────────────────────────

out() { [[ "$SILENT" == "1" ]] || echo "$@"; }
err() { [[ "$SILENT" == "1" ]] || echo "$@" >&2; }

die() { err "Error: $*"; exit 1; }

config_dir() {
    [[ -n "${HOME:-}" ]] || die "\$HOME is not set"
    echo "$HOME/.config/zenbuser"
}

# ── config ───────────────────────────────────────────────────────────────────
# Reads zenbuser.toml with a minimal line-by-line TOML parser.
# Supports [sections], key = "value", and key = ["a","b"] arrays.

declare -A CFG  # flat key→value store, e.g. CFG[screenshot.tool]

load_config() {
    local dir; dir="$(config_dir)"
    local path="$dir/zenbuser.toml"
    [[ -f "$path" ]] || die "could not read config at $path"

    local section="" line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        # strip comments and leading/trailing whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # section header
        if [[ "$line" =~ ^\[([a-zA-Z0-9_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        # key = value
        if [[ "$line" =~ ^([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            local full_key="${section:+$section.}$key"

            # inline array  ["a", "b", ...]  → space-separated
            if [[ "$value" =~ ^\[(.+)\]$ ]]; then
                local inner="${BASH_REMATCH[1]}"
                # strip quotes, commas → space-separated list
                inner="${inner//\"/}"
                inner="${inner//,/ }"
                # collapse extra spaces
                read -ra _arr <<< "$inner"
                CFG["$full_key"]="${_arr[*]}"
            else
                # strip surrounding quotes
                value="${value#\"}"
                value="${value%\"}"
                CFG["$full_key"]="$value"
            fi
        fi
    done < "$path"
}

validate_config() {
    local rb="${CFG[filename.random_bytes]:-0}"
    (( rb >= 8 )) || die "filename.random_bytes must be >= 8"

    [[ -n "${CFG[screenshot.allowed_mime_types]:-}" ]] \
        || die "screenshot.allowed_mime_types must not be empty"

    local td="${CFG[screenshot.temp_dir]:-}"
    [[ -d "$td" ]] \
        || die "screenshot.temp_dir '$td' does not exist or is not a directory"

    local upload_url="${CFG[upload.url]:-}"
    [[ "$upload_url" == https://* ]] \
        || die "upload.url must use HTTPS (got: '$upload_url')"

    local timeout="${CFG[upload.timeout_secs]:-30}"
    (( timeout > 0 )) || die "upload.timeout_secs must be > 0"
}

# ── random filename ───────────────────────────────────────────────────────────

random_hex() {
    local n="$1"
    # read n bytes from /dev/urandom and hex-encode them
    xxd -l "$n" -p /dev/urandom | tr -d '\n'
}

random_filename() {
    local hex; hex="$(random_hex "${CFG[filename.random_bytes]}")"
    echo "${hex}.${CFG[filename.extension]}"
}

# ── screenshot ────────────────────────────────────────────────────────────────

capture_screenshot() {
    local temp_file="$1"
    local tool="${CFG[screenshot.tool]}"
    local output_mode="${CFG[screenshot.output]}"
    # args is stored space-separated; split into array
    read -ra tool_args <<< "${CFG[screenshot.args]:-}"

    case "$output_mode" in
        stdout)
            local stdout
            if ! stdout="$("$tool" "${tool_args[@]}" 2>/tmp/zenbuser_stderr)"; then
                die "'$tool' exited with error: $(cat /tmp/zenbuser_stderr)"
            fi
            [[ -n "$stdout" ]] || die "Screenshot tool produced no output"
            printf '%s' "$stdout" > "$temp_file"
            ;;
        file)
            if ! "$tool" "${tool_args[@]}" "$temp_file" 2>/tmp/zenbuser_stderr; then
                die "'$tool' exited with error: $(cat /tmp/zenbuser_stderr)"
            fi
            [[ -f "$temp_file" ]] \
                || die "Screenshot tool exited successfully but created no file"
            ;;
        *)
            die "Unknown screenshot output mode '$output_mode'"
            ;;
    esac

    # MIME type check
    local mime
    mime="$(file --mime-type -b "$temp_file")" \
        || die "'file' exited with error"

    local allowed="${CFG[screenshot.allowed_mime_types]}"
    local found=0
    for m in $allowed; do
        [[ "$m" == "$mime" ]] && found=1 && break
    done
    (( found )) \
        || die "MIME type '$mime' is not allowed. Allowed: $allowed"
}

# ── upload ────────────────────────────────────────────────────────────────────

upload_screenshot() {
    local temp_file="$1"
    local upload_name; upload_name="$(random_filename)"
    local base_url="${CFG[upload.url]}"
    local param="${CFG[upload.filename_param]}"
    local content_type="${CFG[upload.content_type]}"
    local timeout="${CFG[upload.timeout_secs]:-30}"

    # append query param (simple; URL-encode the filename value)
    local encoded_name
    encoded_name="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$upload_name")"
    local url="${base_url}?${param}=${encoded_name}"

    local response
    response="$(curl -s --fail-with-body --max-time "$timeout" \
        -H "Content-Type: $content_type" \
        --data-binary "@$temp_file" \
        "$url")" \
        || die "curl failed"

    echo "$response"
}

# ── JSON path ─────────────────────────────────────────────────────────────────
# Extracts a dotted-path value from JSON using python3 (portable, no jq dep).

json_path() {
    local json="$1" path="$2"
    python3 - "$json" "$path" <<'EOF'
import sys, json
data = json.loads(sys.argv[1])
for key in sys.argv[2].split('.'):
    if not isinstance(data, dict) or key not in data:
        sys.exit(1)
    data = data[key]
if isinstance(data, str):
    print(data)
else:
    print(json.dumps(data))
EOF
}

extract_url() {
    local response="$1"
    local url_path="${CFG[upload.response_url_path]}"
    local error_path="${CFG[upload.response_error_path]}"

    local extracted_url
    if extracted_url="$(json_path "$response" "$url_path" 2>/dev/null)"; then
        # validate scheme
        [[ "$extracted_url" == http://* || "$extracted_url" == https://* ]] \
            || die "Server returned a URL with unexpected scheme: '$extracted_url'"
        echo "$extracted_url"
        return
    fi

    local error_msg
    error_msg="$(json_path "$response" "$error_path" 2>/dev/null)" \
        || error_msg="Unknown error (neither URL nor error field found in response)"
    die "$error_msg"
}

# ── clipboard ─────────────────────────────────────────────────────────────────

copy_to_clipboard() {
    local text="$1"
    local tool="${CFG[clipboard.tool]}"
    read -ra clip_args <<< "${CFG[clipboard.args]:-}"
    local use_stdin="${CFG[clipboard.use_stdin]:-false}"

    if [[ "$use_stdin" == "true" ]]; then
        printf '%s' "$text" | "$tool" "${clip_args[@]}" \
            || die "'$tool' exited with error"
    else
        "$tool" "${clip_args[@]}" "$text" \
            || die "'$tool' exited with error"
    fi
}

# ── notification ──────────────────────────────────────────────────────────────

send_notification() {
    local temp_file="$1"
    local tool="${CFG[notification.tool]}"
    local message="${CFG[notification.message]}"
    read -ra notif_args <<< "${CFG[notification.args]:-}"
    local include_icon="${CFG[notification.include_screenshot_as_icon]:-false}"

    local cmd=("$tool" "$message" "${notif_args[@]}")
    [[ "$include_icon" == "true" ]] && cmd+=("-i" "$temp_file")

    "${cmd[@]}" || die "'$tool' exited with error"
}

# ── acknowledgement ───────────────────────────────────────────────────────────

ensure_acknowledged() {
    local dir; dir="$(config_dir)"
    mkdir -p "$dir" || die "failed to create ~/.config/zenbuser"

    local flag="$dir/.z"
    [[ -f "$flag" ]] && return

    cat >&2 <<'EOF'

zenbuser uploads files to third-party support platform endpoints
(zendesk and its customers). these endpoints are not intended as
general-purpose file hosts.

by continuing you confirm that:

  1. you are the sole person responsible for any content you upload
  2. you will not upload illegal, harmful, or infringing content
  3. you understand your uploads may be removed at any time
  4. the author of this software bears zero liability for any
     consequences arising from your use of it — including but not
     limited to IP bans, content removal, or legal action taken
     against YOU by the platform
  5. this software is provided as-is, without any warranty

the author is not affiliated with zendesk, inc. or any of its
customers in any way.

EOF

    printf 'do you understand and accept these terms? [Y/n] ' >&2
    local input
    read -r input </dev/tty
    input="${input,,}"  # lowercase

    case "${input:-y}" in
        y|yes)
            touch "$flag" || die "failed to write acknowledgement file"
            echo >&2
            ;;
        *)
            echo -e "\nbye then." >&2
            exit 0
            ;;
    esac
}

# ── version ───────────────────────────────────────────────────────────────────

print_version() {
    cat <<EOF
zenbuser v${VERSION}

This software is released into the public domain under The Unlicense.
The author provides this software as-is, without warranty of any kind.
The author is not responsible for any damage, data loss, or other consequences
arising from its use. Use at your own risk.
EOF
}

# ── main ──────────────────────────────────────────────────────────────────────

SILENT=0
DO_VERSION=0

for arg in "$@"; do
    case "$arg" in
        --version|-v) DO_VERSION=1 ;;
        --silent|-s)  SILENT=1 ;;
        *)
            echo "Error: unknown flag '$arg'" >&2
            echo "Usage: zenbuser [--version | -v] [--silent | -s]" >&2
            exit 1
            ;;
    esac
done

if (( DO_VERSION )); then
    print_version
    exit 0
fi

ensure_acknowledged

load_config
validate_config

TEMP_FILENAME="$(random_filename)"
TEMP_FILE="${CFG[screenshot.temp_dir]}/$TEMP_FILENAME"
DELETE_TEMP="${CFG[cleanup.delete_temp_file]:-false}"

cleanup() {
    [[ "$DELETE_TEMP" == "true" && -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
}
trap cleanup EXIT

capture_screenshot "$TEMP_FILE"

RESPONSE="$(upload_screenshot "$TEMP_FILE")"
URL="$(extract_url "$RESPONSE")"

copy_to_clipboard "$URL"
send_notification "$TEMP_FILE"

out "$URL"
