#!/bin/zsh
set -euo pipefail

TEST_DIRECTORY="$(mktemp -d /tmp/cappy-keychain-test.XXXXXX)"
TEST_KEYCHAIN="$TEST_DIRECTORY/test.keychain-db"
TEST_SERVICE="ai.upriver.cappy.keychain-write-test"
TEST_PASSWORD="cappy-keychain-test"

cleanup() {
    /usr/bin/security delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1 || true
    [[ "$TEST_DIRECTORY" == /tmp/cappy-keychain-test.* ]] && /bin/rm -r -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

/usr/bin/security create-keychain -p "$TEST_PASSWORD" "$TEST_KEYCHAIN"
/usr/bin/security unlock-keychain -p "$TEST_PASSWORD" "$TEST_KEYCHAIN"

first_hex="$(printf '41%.0s' {1..2048})"
/usr/bin/security add-generic-password \
    -a cappy-test -s "$TEST_SERVICE" -X "$first_hex" "$TEST_KEYCHAIN"
first_value="$(/usr/bin/security find-generic-password -a cappy-test -s "$TEST_SERVICE" -w "$TEST_KEYCHAIN")"
[[ "$(LC_ALL=C printf '%s' "$first_value" | wc -c | tr -d ' ')" == "2048" ]]

second_hex="$(printf '42%.0s' {1..4096})"
/usr/bin/security add-generic-password \
    -U -a cappy-test -s "$TEST_SERVICE" -X "$second_hex" "$TEST_KEYCHAIN"
second_value="$(/usr/bin/security find-generic-password -a cappy-test -s "$TEST_SERVICE" -w "$TEST_KEYCHAIN")"
[[ "$(LC_ALL=C printf '%s' "$second_value" | wc -c | tr -d ' ')" == "4096" ]]

unset first_hex first_value second_hex second_value
print "keychain-write: all checks passed"
