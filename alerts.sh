#!/bin/bash
# shellcheck disable=SC2002

token="UNSET"
logfile=/tmp/wallapop-alerts.log

debug() {
    local message=$1

    echo "$message" >&2
    logger -i wallapop-alerts "$message"
}

debug_pipe() {
    local msg=$1

    tee >(
        debug "${msg}$(cat)"
    )
}

echo2() {
    local contents=$1

    if test "$contents"; then
        echo "${contents}"
    fi
}

first_or_fail() {
    grep -m1 "."
}

if_not_empty() {
    local contents
    contents=$(cat)

    if test "$contents"; then
        printf %s "${contents}" | "$@"
    fi
}

api() {
    local path=$1
    local url

    if [[ $path == http* ]]; then
        url=$path
    else
        url="https://api.wallapop.com/api/v3${path}"
    fi

    debug "GET $url"

    curl -sS "$url" \
        -H 'X-DeviceOS: 0' \
        -H 'X-AppVersion: 81890' \
        -H "Authorization: Bearer $token" | jq
}

get_alerts() {
    local alerts
    alerts=$(api "/searchalerts/savedsearch/")

    debug "Alerts defined by user: $(echo "$alerts" | jq 'length')"
    alerts_active=$(echo "$alerts" | jq -r '.[] | select(.alert.hits > 0) | .id') || return 1
    debug "Alerts triggered: $(echo2 "$alerts_active" | wc -l)"

    if test -z "$alerts_active"; then return; fi

    echo "https://es.wallapop.com/app/favorites/searches"
    echo

    echo2 "$alerts_active" | while read -r id; do
        api "/searchalerts/savedsearch/${id}/search" |
            jq -r '.new.search_objects[] | [.title, .price] | @tsv'
    done
}

send_email() {
    local subject=$1 to=$2
    debug "Send email: subject=$subject to=$to"

    sendEmail \
        -s "smtp.gmail.com:587" \
        -o tls=yes \
        -xu "$SMTP_USER" \
        -xp "$SMTP_PASSWORD" \
        -f "$SMTP_USER" \
        -u "$subject" \
        -t "$to"
}

get_token() {
    local debug_url=$1
    local webso_url

    debug "Continue chrome"
    pkill -CONT chrome

    webso_url=$(
        curl --connect-timeout 2 -sS "$debug_url/json" |
            jq -r '.[0] | .webSocketDebuggerUrl' |
            first_or_fail
    )
    debug "Websocket: $webso_url"

    debug "Navigate to home"
    jq -n -c -r '{id: 1, method: "Page.navigate", params: {url: "https://es.wallapop.com/wall"}}' |
        websocat -n1 "$webso_url" | jq -rc >/dev/null

    sleep 5

    debug "Get cookies"
    token=$(
        echo '{"id": 1, "method": "Network.getCookies", "params": {}}' |
            websocat "$webso_url" -n1 |
            jq -r '.result.cookies[] | select(.name == "accessToken") | .value' |
            first_or_fail
    )

    debug "Token: $token"

    debug "Stop chrome"
    pkill -STOP chrome

    echo "$token"
}

run() {
    set -e -u -o pipefail
    local email=$1
    local alerts

    token=$(get_token "http://localhost:9222")
    alerts=$(get_alerts) || return 1

    if test "$alerts"; then
        echo "$alerts" | send_email "Wallapop alert" "$email"
    fi

    debug "Done"
}

send_email_on_error() {
    local subject=$1 to=$2
    shift 2

    exec > >(tee -a $logfile) 2>&1

    if ! "$@"; then
        cat "$logfile" | send_email "$subject" "$to"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    email=$1
    send_email_on_error "Wallapop alert (error)" "$email" run "$email"
fi
