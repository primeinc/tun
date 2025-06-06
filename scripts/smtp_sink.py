#!/usr/bin/env python3
"""
Simple SMTP sink server that dumps incoming emails to console.
Used for testing MX record functionality.
"""

import asyncio
import signal
import sys
import logging
from aiosmtpd.controller import Controller

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class ConsoleHandler:
    async def handle_DATA(self, server, session, envelope):
        """Handle incoming email data"""
        try:
            logger.info("=== NEW EMAIL ===")
            logger.info(f"From: {envelope.mail_from}")
            logger.info(f"To: {envelope.rcpt_tos}")
            
            # Safely decode email content
            try:
                content = envelope.content.decode('utf8', errors='replace')
            except Exception as e:
                content = f"[Unable to decode content: {e}]"
            
            logger.info(f"Data:\n{content}")
            logger.info("="*40)
            return '250 Message accepted for delivery'
        except Exception as e:
            logger.error(f"Error handling email: {e}")
            return '451 Temporary failure, please try again later'

# Global controller reference for signal handling
controller = None

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    logger.info(f"Received signal {signum}, shutting down...")
    if controller:
        controller.stop()
    sys.exit(0)

if __name__ == '__main__':
    # Set up signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        # Create and start the SMTP controller
        controller = Controller(
            ConsoleHandler(), 
            hostname='0.0.0.0', 
            port=25,
            decode_data=False,  # We'll decode manually for better error handling
            max_command_size_limit=512,
            max_data_size_limit=1024*1024  # 1MB limit
        )
        controller.start()
        logger.info("SMTP sink server started on port 25")
        
        # Run the event loop
        asyncio.get_event_loop().run_forever()
    except Exception as e:
        logger.error(f"Failed to start SMTP server: {e}")
        sys.exit(1)
    finally:
        if controller:
            controller.stop()