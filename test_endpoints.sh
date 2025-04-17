#!/usr/bin/env bash
# test_endpoints.sh
# Tests Solana validator endpoints (RPC, gRPC, WebSocket)
# for specified regions and provides a summary.

# --- Configuration ---
declare -A RPC_URLS=(
    [NY]="http://rpc.corvus-labs.io/"
    [FRA]="http://45.145.40.196:8899"
    [TYO]="http://2.57.215.164:8899"
)
declare -A WS_URLS=(
    [NY]="ws://rpc.corvus-labs.io/ws"
    [FRA]="ws://45.145.40.196:8900"
    [TYO]="ws://2.57.215.164:8900"
)
declare -A GRPC_URLS=(
    [NY]="grpc.corvus-labs.io:10101"
    [FRA]="45.145.40.196:10101"
    [TYO]="2.57.215.164:10101"
)

# --- Globals ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROTO_DIR="$SCRIPT_DIR/proto"
PROTO_FILE="$PROTO_DIR/geyser.proto"
AUTH_TOKEN=""
SELECTED_REGIONS=()
declare -A TEST_RESULTS 

# --- Helper Functions ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    local missing_deps=0
    local deps=("curl" "grpcurl" "jq" "node" "timeout" "grep" "wc" "head" "xargs") 
    echo "Checking dependencies..."
    for cmd in "${deps[@]}"; do
        if ! command_exists "$cmd"; then
            if [[ "$cmd" == "timeout" ]]; then
                echo "Warning: Command '$cmd' not found. gRPC test might hang."
            elif [[ "$cmd" == "jq" ]]; then
                 echo "Warning: Command '$cmd' not found. JSON output will not be formatted."
            else
                echo "Error: Command '$cmd' not found. Please install it."
                missing_deps=1
            fi
        fi
    done
    if command_exists "node"; then
        if ! node -e "try { require('ws'); } catch (e) { process.exit(1); }" > /dev/null 2>&1; then
           echo "Error: Node.js 'ws' package not found. Please run: npm install ws"
           missing_deps=1
        fi
    else
        echo "Error: 'node' command not found, required for WebSocket test."
        missing_deps=1
    fi
    if [[ ! -f "$PROTO_FILE" ]]; then
        echo "Error: Proto file not found at '$PROTO_FILE'."
        missing_deps=1
    fi
    if [[ "$missing_deps" -eq 1 ]]; then
        echo "Dependency check failed. Please install missing tools and try again."
        exit 1
    fi
    echo "Dependencies OK."
}

# Function to print compact JSON or raw string
print_compact_or_raw() {
    local input_str="$1"
    if command_exists jq; then
        if jq -e . >/dev/null 2>&1 <<< "$input_str"; then
             echo "$input_str" | jq -c .
        else
             echo "Non-JSON Response: $input_str"
        fi
    else
         echo "$input_str"
    fi
}

# Function to perform tests for a given region and store results
run_tests() {
    local region_name="$1"
    local rpc_url="$2"
    local ws_url="$3"
    local grpc_url="$4"

    local rpc_status="Fail"
    local grpc_status="Fail"
    local ws_status="Fail"
    local overall_status=1

    echo "================== Testing Region: $region_name =================="

    # --- RPC Test ---
    echo "--- RPC ($rpc_url)"
    local rpc_slot_payload='{"jsonrpc":"2.0","id":1,"method":"getSlot","params": [{"commitment": "confirmed"}]}'
    local rpc_health_payload='{"jsonrpc":"2.0","id":2,"method":"getHealth"}'
    local rpc_slot_ok=false
    local rpc_health_ok=false

    echo -n "  getSlot: "
    RPC_SLOT_RESPONSE=$(curl --fail --connect-timeout 10 -s -X POST -H "Content-Type: application/json" -d "$rpc_slot_payload" "$rpc_url")
    local rpc_slot_exit_code=$?
    if [[ $rpc_slot_exit_code -eq 0 ]]; then
        print_compact_or_raw "$RPC_SLOT_RESPONSE"
        rpc_slot_ok=true
    else
        echo "FAIL (Exit code: $rpc_slot_exit_code)"
    fi

    echo -n "  getHealth: "
    RPC_HEALTH_RESPONSE=$(curl --fail --connect-timeout 10 -s -X POST -H "Content-Type: application/json" -d "$rpc_health_payload" "$rpc_url")
    local rpc_health_exit_code=$?
     if [[ $rpc_health_exit_code -eq 0 ]]; then
        print_compact_or_raw "$RPC_HEALTH_RESPONSE"
        rpc_health_ok=true
    else
        echo "FAIL (Exit code: $rpc_health_exit_code)"
    fi

    if $rpc_slot_ok && $rpc_health_ok; then rpc_status="Pass"; fi
    TEST_RESULTS["${region_name}_RPC"]=$rpc_status

    # --- gRPC Test ---
    echo "--- gRPC ($grpc_url)"
    local grpc_request='{
      "commitment": "1", "slots": { "slot": {} }, "accounts": {}, "accountsDataSlice": [],
      "transactions": {}, "transactionsStatus": {}, "entry": {}, "blocks": {}, "blocksMeta": {}
    }'
    echo -n "  Slot Updates (max 5): "

    local timeout_cmd_array=()
    if command_exists timeout; then timeout_cmd_array=("timeout" "15s"); fi
    local process_cmd_array=("cat")
    if command_exists jq; then process_cmd_array=("jq" "-c" "select(has(\"slot\"))"); fi

    local grpc_output
    local grpc_exit_code
    grpc_output=$( "${timeout_cmd_array[@]}" grpcurl -plaintext -proto "$PROTO_FILE" -import-path "$PROTO_DIR" \
        -d "$grpc_request" "$grpc_url" geyser.Geyser/Subscribe 2>&1 | \
        "${process_cmd_array[@]}" | head -n 5 )
    grpc_exit_code=${PIPESTATUS[$((${#timeout_cmd_array[@]} > 0 ? 1 : 0))]}
    local timeout_exit_code=${PIPESTATUS[0]}

    if grep -q -E "Failed to dial target|Failed parsing proto file|rpc error: code =" <<< "$grpc_output" && [[ $grpc_exit_code -ne 0 ]]; then
       echo "FAIL (Connection/Execution Error)"
       echo "    Error details: $(echo "$grpc_output" | head -n 1)"
    elif [[ $grpc_exit_code -eq 0 && -n "$grpc_output" ]] || \
         [[ $grpc_exit_code -eq 141 && -n "$grpc_output" ]] || \
         [[ ${#timeout_cmd_array[@]} -gt 0 && $timeout_exit_code -eq 124 && -n "$grpc_output" ]]; then
            local first_grpc_message
            first_grpc_message=$(echo "$grpc_output" | head -n 1)
            echo "Pass (First: ${first_grpc_message})"
            echo "    Received: $(echo "$grpc_output" | wc -l | xargs) total messages matching filter." 
            grpc_status="Pass"
    elif [[ ${#timeout_cmd_array[@]} -gt 0 && $timeout_exit_code -eq 124 && -z "$grpc_output" ]]; then
         echo "FAIL (Timeout with no messages)"
    else
        if [[ -z "$grpc_output" ]]; then
             echo "FAIL (Exit code: $grpc_exit_code, No matching messages received)"
        else
             echo "FAIL (Exit code: $grpc_exit_code)"
             echo "    Output/Error: $(echo "$grpc_output" | head -n 1)"
        fi
    fi
    TEST_RESULTS["${region_name}_GRPC"]=$grpc_status

    # --- WebSocket Test ---
    echo "--- WebSocket ($ws_url)"
    echo -n "  Slot Subscription (3s): "

    local node_script
    node_script=$(mktemp "${SCRIPT_DIR}/test_ws.XXXXXX.js")
    trap 'rm -f "$node_script" > /dev/null 2>&1' EXIT SIGINT SIGTERM

cat << 'EOF' > "$node_script"
const WebSocket = require('ws');
const endpoint = process.argv[2];
const region = process.argv[3];
const timeoutMs = 3000;
const connectionTimeoutMs = 10000;
const subscribePayload = {"jsonrpc":"2.0", "id":1, "method":"slotSubscribe"};
let messageCount = 0;
let connectionTimer = null;
let runTimer = null;
let ws = null;
let exited = false;
let firstMessage = null;

function safeJsonStringify(obj) {
    try {
        // Attempt to parse and restringify for consistent formatting
        return JSON.stringify(JSON.parse(obj));
    } catch {
        // If parsing fails, return a truncated original string
        const str = String(obj);
        return str.length > 70 ? str.substring(0, 67) + "..." : str;
    }
}

function exitScript(code, message) {
    if (exited) return;
    exited = true;
    clearTimeout(connectionTimer);
    clearTimeout(runTimer);
    const status = code === 0 ? "Pass" : "Fail";
    let detail = message || (code === 0 ? "OK" : "Unknown Error");
    if (code === 0 && messageCount > 0 && firstMessage) {
         detail = `Received ${messageCount} messages. First: ${safeJsonStringify(firstMessage)}`;
    } else if (code === 0 && messageCount === 0) {
        detail = "Connected but received no subscription messages.";
    }
    console.log(`${status} (${detail})`);

    if (ws && ws.readyState === WebSocket.OPEN) {
        try { ws.close(code === 0 ? 1000 : 1001); } catch (e) {}
    }
    process.exit(code);
}

connectionTimer = setTimeout(() => {
    exitScript(1, `Connection timeout (${connectionTimeoutMs / 1000}s)`);
}, connectionTimeoutMs);

try {
    ws = new WebSocket(endpoint, { handshakeTimeout: connectionTimeoutMs - 500 });
} catch (e) { exitScript(1, `WebSocket creation failed: ${e.message}`); }

ws.on('open', () => {
    clearTimeout(connectionTimer);
    try {
        ws.send(JSON.stringify(subscribePayload));
    } catch (err) { exitScript(1, `Failed to send message: ${err.message}`); return; }

    runTimer = setTimeout(() => {
        exitScript(0, `${timeoutMs/1000}s elapsed`);
    }, timeoutMs);
});

ws.on('message', (data) => {
    messageCount++;
    if (messageCount === 1) {
         firstMessage = Buffer.isBuffer(data) ? data.toString('utf8') : data;
    }
});

ws.on('error', (error) => {
    exitScript(1, `WebSocket error: ${error.message}`);
});

ws.on('close', (code, reason) => {
    if (!exited) {
        const reasonStr = reason ? reason.toString() : 'N/A';
        const exitCode = (code === 1000 && messageCount > 0) ? 0 : 1; // Require messages for code 1000 pass on close
        const exitMsg = messageCount > 0 ?
             `Connection closed (Code: ${code}, Reason: ${reasonStr})` :
             `Connection closed without messages (Code: ${code}, Reason: ${reasonStr})`;
        exitScript(exitCode, exitMsg);
    }
});
EOF

    ws_output=$(node "$node_script" "$ws_url" "$region_name")
    local node_exit_code=$?
    rm -f "$node_script" > /dev/null 2>&1
    trap - EXIT SIGINT SIGTERM

    if [[ $node_exit_code -eq 0 ]]; then ws_status="Pass"; fi
    echo "$ws_output"
    TEST_RESULTS["${region_name}_WS"]=$ws_status

    if [[ "$rpc_status" == "Pass" && "$grpc_status" == "Pass" && "$ws_status" == "Pass" ]]; then
        overall_status=0
    fi

    echo
    return $overall_status
}

# --- Main Script Logic ---
check_dependencies
echo

# Prompt for region selection
echo "Select the region(s) to test:"
PS3="Enter number (or 'ALL' - type 4): "
options=("NY" "FRA" "TYO" "ALL" "Quit")
while true; do
    select opt in "${options[@]}"; do
        if [[ -n "$opt" ]]; then
            case $opt in
                "NY") SELECTED_REGIONS+=("NY"); break ;;
                "FRA") SELECTED_REGIONS+=("FRA"); break ;;
                "TYO") SELECTED_REGIONS+=("TYO"); break ;;
                "ALL") SELECTED_REGIONS=("NY" "FRA" "TYO"); break ;;
                "Quit") echo "Exiting."; exit 0 ;;
                *) echo "Invalid option '$REPLY'. Please try again." ; break;;
            esac
        else
             echo "Invalid input '$REPLY'. Please enter a number from the list."
             break
        fi
    done
    if [[ ${#SELECTED_REGIONS[@]} -gt 0 ]]; then break; fi
done
echo "Selected regions: ${SELECTED_REGIONS[*]}"

# Prompt for NY auth token if needed
needs_auth=false
for region in "${SELECTED_REGIONS[@]}"; do if [[ "$region" == "NY" ]]; then needs_auth=true; break; fi; done
if [[ "$needs_auth" == true ]]; then
    while [[ -z "$AUTH_TOKEN" ]]; do
        read -p "Enter the authentication token for the NY region (required): " AUTH_TOKEN
        if [[ -z "$AUTH_TOKEN" ]]; then
             read -p "No token entered. Proceed without token? (Tests for NY will likely fail) [y/N]: " confirm_no_token
             if [[ "${confirm_no_token,,}" == "y" || "${confirm_no_token,,}" == "yes" ]]; then
                 echo "Warning: Proceeding without auth token for NY."
                 AUTH_TOKEN=""; break
             else continue; fi
        fi
    done
fi
echo

# Iterate and run tests
declare -a failed_regions
for region in "${SELECTED_REGIONS[@]}"; do
    rpc_endpoint="${RPC_URLS[$region]}"
    ws_endpoint="${WS_URLS[$region]}"
    grpc_endpoint="${GRPC_URLS[$region]}"
    if [[ "$region" == "NY" && -n "$AUTH_TOKEN" ]]; then
        rpc_endpoint="${rpc_endpoint}?api-key=${AUTH_TOKEN}"
        ws_endpoint="${ws_endpoint}?api-key=${AUTH_TOKEN}"
    elif [[ "$region" == "NY" && -z "$AUTH_TOKEN" ]]; then
        echo "Warning: Testing NY region without an auth token."
    fi

    run_tests "$region" "$rpc_endpoint" "$ws_endpoint" "$grpc_endpoint"
    if [[ $? -ne 0 ]]; then
        failed_regions+=("$region")
    fi
done

# --- Final Summary ---
echo "==================== Test Summary ===================="
overall_success=true
for region in "${SELECTED_REGIONS[@]}"; do
    rpc_res=${TEST_RESULTS[${region}_RPC]:-Fail}
    grpc_res=${TEST_RESULTS[${region}_GRPC]:-Fail}
    ws_res=${TEST_RESULTS[${region}_WS]:-Fail}

    region_full_name=$region
    [[ "$region" == "FRA" ]] && region_full_name="Frankfurt"
    [[ "$region" == "NY" ]] && region_full_name="New York"
    [[ "$region" == "TYO" ]] && region_full_name="Tokyo"

    echo "${region_full_name} Node:"
    echo "  ${rpc_res} - RPC"
    echo "  ${grpc_res} - gRPC"
    echo "  ${ws_res} - WebSocket"
    echo

    if [[ "$rpc_res" == "Fail" || "$grpc_res" == "Fail" || "$ws_res" == "Fail" ]]; then
        overall_success=false
    fi
done
echo "===================================================="

if $overall_success; then
    echo "All tests passed for selected regions."
    exit 0
else
    echo "One or more tests FAILED. Check summary above."
    exit 1
fi
