# Multi-Region Solana Endpoint Test Script

## Description

This Bash script (`test_endpoints.sh`) provides a convenient way to test connectivity and basic functionality of Solana validator endpoints (RPC, gRPC, WebSocket) across multiple geographical regions (New York, Frankfurt, Tokyo).

It is designed to be run from a user's local machine or any server to verify that the necessary ports are open, authentication (where applicable) is working, and the endpoints are responding correctly to basic requests.

The script performs the following checks for each selected region:

*   **RPC:** Calls `getSlot` and `getHealth` methods via HTTP POST.
*   **gRPC:** Connects to the gRPC port, subscribes to slot updates using the `geyser.proto` definition, and attempts to receive up to 5 messages.
*   **WebSocket:** Connects via WebSocket, sends a `slotSubscribe` request, and listens for messages for a few seconds.

## Features

*   Tests RPC, gRPC, and WebSocket endpoints.
*   Supports multiple regions: New York (NY), Frankfurt (FRA), Tokyo (TYO).
*   Allows testing specific regions or all regions (`ALL` option).
*   Prompts for user input for region selection.
*   Handles NY-specific authentication by prompting for an API key (other regions assume IP whitelisting).
*   Provides concise Pass/Fail results during execution, including the first message received for gRPC and WebSocket streams.
*   Outputs a clear summary report at the end indicating the status of each test for each selected region.
*   Includes dependency checks before running tests.

## Requirements

### Software

*   **Operating System:** Linux or macOS (Bash environment). Can also be run under Windows Subsystem for Linux (WSL).
*   **Shell:** Bash (version 4+ recommended for associative arrays).
*   **Required Tools:**
    *   `curl`: For making HTTP RPC requests.
    *   `grpcurl`: For making gRPC requests.
    *   `jq`: For parsing and formatting JSON output.
    *   `node`: Node.js runtime (v12+ recommended) for the WebSocket test fallback.
    *   `npm`: Node Package Manager (usually included with Node.js) to install the `ws` package.
    *   `timeout`: (Recommended, often part of `coreutils`) To prevent the gRPC test from hanging indefinitely.
    *   Standard Unix Utilities: `grep`, `head`, `wc`, `xargs`, `mktemp`.

### Files

*   **`test_endpoints.sh`:** The main script file.
*   **`proto/geyser.proto`:** The Solana Geyser plugin Protobuf definition file. This **must** be placed in a subdirectory named `proto` relative to the script file.

    ```
    .
    ├── test_endpoints.sh
    └── proto/
        └── geyser.proto
    ```

### Network Access

*   The machine running the script must have outbound network access to the Solana endpoints being tested on their respective ports (HTTP, gRPC, WebSocket).
*   For the Frankfurt (FRA) and Tokyo (TYO) endpoints used in this script, ensure the IP address of the machine running the script is whitelisted if required by the service provider. The New York (NY) endpoint uses API key authentication instead.

## Setup

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/corvus-labs-io/Test-Endpoints.git
    cd Test-Endpoints
    ```

2.  **Ensure File Structure:** Verify that `geyser.proto` is inside the `proto/` subdirectory.

3.  **Install Dependencies:**
    *   **Debian/Ubuntu:**
        ```bash
        sudo apt update && sudo apt install -y curl grpcurl jq nodejs npm coreutils grep coreutils xargs
        ```
        *(Note: `timeout` is part of `coreutils`. Check your `nodejs`/`npm` versions if needed.)*
    *   **macOS (using Homebrew):**
        ```bash
        brew install curl grpcurl jq node grep coreutils findutils
        ```
        *(Note: `timeout` is `gtimeout` from `coreutils` on macOS, the script uses `timeout` so ensure `coreutils` binaries are in PATH or adjust script if needed)*
    *   **Other Linux Distributions:** Use your distribution's package manager (e.g., `yum`, `dnf`, `pacman`) to install the equivalent packages.

4.  **Install Node.js `ws` Package:** Navigate to the script's directory in your terminal and run:
    ```bash
    npm install ws
    ```
    This will create a `node_modules` directory and a `package.json`/`package-lock.json` file if they don't exist. This installs the package locally for the script to use. Alternatively, install globally (`npm install -g ws`), but local installation is generally preferred.

5.  **Make Script Executable:**
    ```bash
    chmod +x test_endpoints.sh
    ```

## Usage

1.  **Run the Script:**
    ```bash
    ./test_endpoints.sh
    ```

2.  **Select Region(s):** The script will prompt you to choose which region(s) to test. Enter the corresponding number (e.g., `1` for NY, `4` for ALL).

    ```
    Select the region(s) to test:
    1) NY
    2) FRA
    3) TYO
    4) ALL
    5) Quit
    Enter number (or 'ALL' - type 4): 4
    ```

3.  **Enter NY Auth Token (If Applicable):** If you select NY or ALL, the script will prompt for the authentication token (API key) required for the New York endpoints. Paste your token and press Enter.

    ```
    Selected regions: NY FRA TYO
    Enter the authentication token for the NY region (required): your_api_key_here
    ```
    *(Note: If you proceed without a token, NY tests will likely fail.)*

4.  **View Test Progress:** The script will then execute the tests for each selected region, printing concise status updates:

    ```
    ================== Testing Region: NY ==================
    --- RPC (http://rpc.corvus-labs.io/?api-key=...)
      getSlot: {"jsonrpc":"2.0","result":...,"id":1}
      getHealth: {"jsonrpc":"2.0","result":"ok","id":2}
    --- gRPC (grpc.corvus-labs.io:10101)
      Slot Updates (max 5): Pass (First: {"filters":["slot"],"slot":{...}})
        Received: 5 total messages matching filter.
    --- WebSocket (ws://rpc.corvus-labs.io/ws?api-key=...)
      Slot Subscription (3s): Pass (Received 8 messages. First: {"jsonrpc":"2.0","result":...})

    ... (output for other regions) ...
    ```

5.  **Review Final Summary:** After all tests are complete, a final summary is displayed:

    ```
    ==================== Test Summary ====================
    New York Node:
      Pass - RPC
      Pass - gRPC
      Pass - WebSocket

    Frankfurt Node:
      Pass - RPC
      Pass - gRPC
      Pass - WebSocket

    Tokyo Node:
      Pass - RPC
      Pass - gRPC
      Pass - WebSocket

    ====================================================
    All tests passed for selected regions.
    ```

6.  **Check Exit Code:** The script exits with code `0` if all tests for all selected regions passed, and `1` if any test failed.

## Troubleshooting

*   **Dependency Errors:** If the script reports missing commands at startup, ensure all required tools listed in the **Requirements** section are installed correctly and available in your system's `PATH`.
*   **Proto File Not Found:** Verify the `proto/geyser.proto` file path is correct relative to the script.
*   **Network Errors / Timeouts (`curl`, `grpcurl`, WebSocket):**
    *   Check general internet connectivity from the machine running the script.
    *   Verify that firewalls (local or network) are not blocking outbound connections to the required IPs and ports.
    *   For FRA and TYO, confirm your source IP is whitelisted if necessary.
    *   Persistent `timeout` errors on the gRPC test often indicate a network block or the remote service not responding.
*   **Authentication Errors (NY):** Double-check that the API key entered is correct and valid.
*   **WebSocket `ws` Package Error:** Ensure you ran `npm install ws` in the script's directory or installed it globally.
*   **`jq` Errors:** If you see `jq: error:` messages, there might be an issue with how JSON is being piped or the response isn't valid JSON.
*   **Permission Denied:** Ensure the script has execute permissions (`chmod +x test_endpoints.sh`). If creating temporary files fails, check write permissions in the script's directory.

## License

*(Optional: Specify your license here, e.g., MIT License, or refer to a LICENSE file)*
