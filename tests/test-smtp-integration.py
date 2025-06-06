#!/usr/bin/env python3
"""
Integration test for SMTP sink - tests actual SMTP protocol handling
"""

import sys
import os
import smtplib
import subprocess
import time
import socket
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

# Add scripts directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))

def test_smtp_handler():
    """Test the SMTP handler can process emails correctly"""
    print("Testing SMTP handler...")
    
    # Import and test the handler directly
    from smtp_sink import ConsoleHandler
    import asyncio
    
    # Create test envelope
    class MockEnvelope:
        mail_from = "sender@test.com"
        rcpt_tos = ["recipient@test.com"]
        content = b"Subject: Test\r\n\r\nTest message body"
    
    # Test the handler
    handler = ConsoleHandler()
    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(
        handler.handle_DATA(None, None, MockEnvelope())
    )
    loop.close()
    
    assert result == '250 Message accepted for delivery', f"Unexpected response: {result}"
    print("✓ SMTP handler processes emails correctly")
    
def test_smtp_server_locally():
    """Test running the SMTP server on a high port"""
    print("\nTesting SMTP server on localhost:2525...")
    
    # Start the server on port 2525 (no root required)
    server_script = """
import sys
sys.path.insert(0, '/mnt/c/Users/WillPeters/dev/tun/scripts')
from smtp_sink import ConsoleHandler
from aiosmtpd.controller import Controller
import threading
import time

controller = Controller(ConsoleHandler(), hostname='127.0.0.1', port=2525)
controller.start()
print("Test server started on port 2525", flush=True)

# Keep running for 10 seconds
time.sleep(10)
controller.stop()
"""
    
    # Start server in background
    proc = subprocess.Popen(
        [sys.executable, '-c', server_script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    
    # Wait for server to start
    time.sleep(2)
    
    try:
        # Test connection
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        result = sock.connect_ex(('127.0.0.1', 2525))
        sock.close()
        
        if result == 0:
            print("✓ SMTP server accepts connections")
            
            # Try to send an email
            try:
                server = smtplib.SMTP('127.0.0.1', 2525)
                server.set_debuglevel(0)
                
                msg = MIMEMultipart()
                msg['From'] = 'test@sender.com'
                msg['To'] = 'test@recipient.com'
                msg['Subject'] = 'Integration Test'
                
                body = "This is a test email from the integration test."
                msg.attach(MIMEText(body, 'plain'))
                
                server.send_message(msg)
                server.quit()
                
                print("✓ Successfully sent test email")
            except Exception as e:
                print(f"✗ Failed to send email: {e}")
        else:
            print("✗ Could not connect to SMTP server")
            
    finally:
        # Stop the server
        proc.terminate()
        proc.wait(timeout=5)
        stdout, stderr = proc.communicate()
        
        # Check if server logged our email
        if "NEW EMAIL" in stdout:
            print("✓ Server logged the email correctly")
        else:
            print("✗ Server did not log the email")
            print(f"Server output: {stdout}")
            print(f"Server errors: {stderr}")

def main():
    print("=== SMTP Sink Integration Tests ===\n")
    
    # Test 1: Handler unit test
    test_smtp_handler()
    
    # Test 2: Local server test
    test_smtp_server_locally()
    
    print("\nIntegration tests completed!")

if __name__ == "__main__":
    main()