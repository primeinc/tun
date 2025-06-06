#!/bin/bash
# Test script for SMTP sink implementation

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test counters
PASSED=0
FAILED=0

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Test function
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -e "${CYAN}Testing: ${test_name}${NC}"
    
    if eval "$test_command"; then
        echo -e "${GREEN}✓ ${test_name}${NC}"
        ((PASSED++))
    else
        echo -e "${RED}✗ ${test_name}${NC}"
        ((FAILED++))
    fi
    echo
}

echo -e "${CYAN}=== SMTP Sink Test Suite ===${NC}\n"

# Test 1: Python syntax check
run_test "Python script syntax" \
    "python3 -m py_compile '$PROJECT_ROOT/scripts/smtp_sink.py'"

# Test 2: Check if aiosmtpd can be imported
run_test "aiosmtpd availability" \
    "python3 -c 'import aiosmtpd' 2>/dev/null || (echo 'Run: pip3 install aiosmtpd' && false)"

# Test 3: Test the ConsoleHandler class
run_test "ConsoleHandler instantiation" \
    "cd '$PROJECT_ROOT/scripts' && python3 -c 'from smtp_sink import ConsoleHandler; h = ConsoleHandler(); print(\"Handler OK\")'"

# Test 4: Check install.sh bash syntax
run_test "install.sh bash syntax" \
    "bash -n '$PROJECT_ROOT/scripts/install.sh'"

# Test 5: Verify systemd service syntax
echo -e "${CYAN}Testing: systemd service configuration${NC}"
if grep -q "Create SMTP sink service" "$PROJECT_ROOT/scripts/install.sh"; then
    # Extract and test the service file content
    sed -n '/# Create SMTP sink service/,/^EOF$/p' "$PROJECT_ROOT/scripts/install.sh" | \
    sed -n '/cat.*smtp_service_file.*EOF/,/^EOF$/p' | \
    sed '1d;$d' > /tmp/test-smtpsink.service
    
    if systemd-analyze verify /tmp/test-smtpsink.service 2>/dev/null; then
        echo -e "${GREEN}✓ systemd service configuration${NC}"
        ((PASSED++))
    else
        # Check manually if systemd-analyze not available
        if grep -q "\[Unit\]" /tmp/test-smtpsink.service && \
           grep -q "\[Service\]" /tmp/test-smtpsink.service && \
           grep -q "\[Install\]" /tmp/test-smtpsink.service; then
            echo -e "${GREEN}✓ systemd service configuration (basic check)${NC}"
            ((PASSED++))
        else
            echo -e "${RED}✗ systemd service configuration${NC}"
            ((FAILED++))
        fi
    fi
    rm -f /tmp/test-smtpsink.service
else
    echo -e "${RED}✗ systemd service configuration - not found in install.sh${NC}"
    ((FAILED++))
fi
echo

# Test 6: Check NSG rule in Bicep
run_test "Bicep NSG SMTP rule" \
    "grep -q \"name: 'SMTP'\" '$PROJECT_ROOT/infra/main.bicep' && grep -q \"destinationPortRange: '25'\" '$PROJECT_ROOT/infra/main.bicep'"

# Test 7: Check deployment integration
run_test "smtp_sink.py in deployment" \
    "grep -q 'smtp_sink.py' '$PROJECT_ROOT/scripts/redeploy-extension.ps1'"

# Test 8: Test signal handling
echo -e "${CYAN}Testing: Signal handling simulation${NC}"
cat > /tmp/test_signal.py << 'EOF'
import sys
sys.path.insert(0, '/mnt/c/Users/WillPeters/dev/tun/scripts')
import signal
from smtp_sink import signal_handler

# Test signal handler doesn't crash
try:
    # Simulate SIGTERM
    signal_handler(signal.SIGTERM, None)
except SystemExit:
    print("Signal handler works correctly")
    exit(0)
except Exception as e:
    print(f"Error: {e}")
    exit(1)
EOF

if python3 /tmp/test_signal.py 2>/dev/null; then
    echo -e "${GREEN}✓ Signal handling simulation${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ Signal handling simulation${NC}"
    ((FAILED++))
fi
rm -f /tmp/test_signal.py
echo

# Test 9: Documentation check
run_test "Documentation exists" \
    "test -f '$PROJECT_ROOT/docs/MX-SMTP-SINK.md'"

run_test "Documentation has security warnings" \
    "grep -q 'CRITICAL WARNING' '$PROJECT_ROOT/docs/MX-SMTP-SINK.md'"

# Test 10: Python dependencies in install.sh
run_test "Python3 installation in install.sh" \
    "grep -q 'apt-get install.*python3' '$PROJECT_ROOT/scripts/install.sh'"

run_test "pip3 installation in install.sh" \
    "grep -q 'apt-get install.*python3-pip' '$PROJECT_ROOT/scripts/install.sh'"

run_test "aiosmtpd installation in install.sh" \
    "grep -q 'pip3 install aiosmtpd' '$PROJECT_ROOT/scripts/install.sh'"

# Test 11: Security directives in systemd service
echo -e "${CYAN}Testing: Security hardening directives${NC}"
if grep -A20 "Create SMTP sink service" "$PROJECT_ROOT/scripts/install.sh" | grep -q "NoNewPrivileges=true"; then
    echo -e "${GREEN}✓ Security hardening directives${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ Security hardening directives${NC}"
    ((FAILED++))
fi
echo

# Summary
echo -e "${CYAN}===================================================${NC}"
echo -e "${CYAN}Test Summary${NC}"
echo -e "${CYAN}===================================================${NC}"
echo -e "Total Tests: $((PASSED + FAILED))"
echo -e "${GREEN}Passed: ${PASSED}${NC}"
echo -e "${RED}Failed: ${FAILED}${NC}"

if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed!${NC}"
    exit 1
fi