#!/usr/bin/env python3
"""
JSON-RPC path rewrite shim for Docker Pyright integration.

This script acts as a transparent proxy between Neovim and Pyright,
translating file paths between host and container environments.
"""

import json
import logging
import os
import subprocess
import sys
import threading
import traceback
from pathlib import Path
from typing import Any, Dict, List, Optional, Union
from urllib.parse import quote, unquote

# Configure logging
LOG_LEVEL = logging.DEBUG if os.environ.get("DEBUG_SHIM") else logging.WARNING
LOG_FILE = os.environ.get("SHIM_LOG_FILE", "/tmp/pyright_shim.log")

logging.basicConfig(
    level=LOG_LEVEL,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stderr)
    ]
)
logger = logging.getLogger(__name__)

# Path mapping configuration from environment
HOST_ROOT = os.environ.get("HOST_ROOT", "/work/host")
CONTAINER_ROOT = os.environ.get("CONTAINER_ROOT", "/work/container")

# Normalize paths
HOST_ROOT = str(Path(HOST_ROOT).resolve())
CONTAINER_ROOT = str(Path(CONTAINER_ROOT).resolve())

logger.info(f"Path mapping initialized: {HOST_ROOT} <-> {CONTAINER_ROOT}")


class PathRewriter:
    """Handles bidirectional path rewriting between host and container."""
    
    # Keys in JSON-RPC messages that typically contain paths
    PATH_KEYS = {
        "uri", "targetUri", "source", "file", "path",
        "rootPath", "rootUri", "workspaceFolders",
        "documentUri", "newUri", "oldUri", "baseUri",
        "referenceUri", "targetRange", "targetSelectionRange"
    }
    
    # Keys that contain arrays of paths
    PATH_ARRAY_KEYS = {
        "workspaceFolders", "files", "includedFiles", "excludedFiles"
    }
    
    @staticmethod
    def encode_uri_component(path: str) -> str:
        """Encode path component for file URI."""
        # Only encode necessary characters, preserve path separators
        return quote(path, safe='/')
    
    @staticmethod
    def decode_uri_component(path: str) -> str:
        """Decode path component from file URI."""
        return unquote(path)
    
    @classmethod
    def rewrite_path(cls, value: Any, from_prefix: str, to_prefix: str) -> Any:
        """
        Rewrite a single path string.
        
        Args:
            value: The value to potentially rewrite
            from_prefix: The prefix to replace
            to_prefix: The prefix to replace with
            
        Returns:
            The rewritten value or original if not a path
        """
        if not isinstance(value, str):
            return value
        
        # Handle file:// URIs
        if value.startswith("file://"):
            path = value[7:]
            
            # Decode percent-encoded paths
            if '%' in path:
                path = cls.decode_uri_component(path)
            
            # Rewrite if path matches
            if path.startswith(from_prefix):
                new_path = to_prefix + path[len(from_prefix):]
                # Re-encode for URI
                return "file://" + cls.encode_uri_component(new_path)
            return value
        
        # Handle file:/// URIs (three slashes)
        if value.startswith("file:///"):
            path = value[8:]
            
            # Decode percent-encoded paths
            if '%' in path:
                path = cls.decode_uri_component(path)
            
            # Rewrite if path matches
            if path.startswith(from_prefix):
                new_path = to_prefix + path[len(from_prefix):]
                return "file:///" + cls.encode_uri_component(new_path)
            return value
        
        # Handle absolute paths
        if value.startswith(from_prefix):
            return to_prefix + value[len(from_prefix):]
        
        return value
    
    @classmethod
    def rewrite_object(cls, obj: Any, from_prefix: str, to_prefix: str) -> Any:
        """
        Recursively rewrite paths in a JSON object.
        
        Args:
            obj: The object to process
            from_prefix: The prefix to replace
            to_prefix: The prefix to replace with
            
        Returns:
            The object with rewritten paths
        """
        if isinstance(obj, dict):
            result = {}
            for key, value in obj.items():
                # Special handling for known path keys
                if key in cls.PATH_KEYS:
                    if isinstance(value, str):
                        result[key] = cls.rewrite_path(value, from_prefix, to_prefix)
                    elif isinstance(value, list):
                        # Handle arrays of paths
                        result[key] = [cls.rewrite_path(item, from_prefix, to_prefix) 
                                     if isinstance(item, str) else 
                                     cls.rewrite_object(item, from_prefix, to_prefix)
                                     for item in value]
                    else:
                        result[key] = cls.rewrite_object(value, from_prefix, to_prefix)
                # Special handling for workspace folders
                elif key == "workspaceFolders" and isinstance(value, list):
                    result[key] = [cls.rewrite_object(item, from_prefix, to_prefix) 
                                 for item in value]
                else:
                    # Recursive processing for other keys
                    result[key] = cls.rewrite_object(value, from_prefix, to_prefix)
            return result
        
        elif isinstance(obj, list):
            return [cls.rewrite_object(item, from_prefix, to_prefix) for item in obj]
        
        elif isinstance(obj, str):
            # Check if this string looks like a path even if not in expected keys
            if obj.startswith(from_prefix) or obj.startswith("file://"):
                return cls.rewrite_path(obj, from_prefix, to_prefix)
        
        return obj


class JsonRpcProxy:
    """JSON-RPC message proxy with path rewriting."""
    
    def __init__(self):
        """Initialize the proxy."""
        self.rewriter = PathRewriter()
        self.child: Optional[subprocess.Popen] = None
        self.running = True
        self.start_server()
    
    def start_server(self) -> None:
        """Start the Pyright language server as a subprocess."""
        try:
            cmd = [sys.executable, "-m", "pyright", "--stdio"]
            logger.info(f"Starting Pyright server: {' '.join(cmd)}")
            
            self.child = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0  # Unbuffered
            )
            
            logger.info(f"Pyright server started with PID {self.child.pid}")
            
            # Start stderr forwarding thread
            stderr_thread = threading.Thread(target=self.forward_stderr, daemon=True)
            stderr_thread.start()
            
        except Exception as e:
            logger.error(f"Failed to start Pyright server: {e}")
            sys.exit(1)
    
    def forward_stderr(self) -> None:
        """Forward stderr from child process to our stderr."""
        try:
            while self.running and self.child and self.child.stderr:
                line = self.child.stderr.readline()
                if not line:
                    break
                sys.stderr.buffer.write(line)
                sys.stderr.buffer.flush()
        except Exception as e:
            logger.error(f"Error forwarding stderr: {e}")
    
    def read_message(self, stream) -> Optional[Dict]:
        """
        Read a JSON-RPC message from a stream.
        
        Args:
            stream: The input stream to read from
            
        Returns:
            The parsed JSON message or None if stream ended
        """
        try:
            headers = {}
            
            # Read headers
            while True:
                line = stream.readline()
                if not line:
                    return None
                if line == b"\r\n":
                    break
                if b":" in line:
                    key, value = line.decode('utf-8', errors='replace').split(":", 1)
                    headers[key.strip().lower()] = value.strip()
            
            # Get content length
            content_length = int(headers.get("content-length", 0))
            if content_length == 0:
                logger.warning("No content-length header found")
                return None
            
            # Read body
            body = stream.read(content_length)
            if len(body) != content_length:
                logger.warning(f"Expected {content_length} bytes, got {len(body)}")
                return None
            
            # Parse JSON
            return json.loads(body.decode('utf-8'))
            
        except json.JSONDecodeError as e:
            logger.error(f"JSON decode error: {e}")
            return None
        except Exception as e:
            logger.error(f"Error reading message: {e}")
            return None
    
    def write_message(self, stream, message: Dict) -> None:
        """
        Write a JSON-RPC message to a stream.
        
        Args:
            stream: The output stream to write to
            message: The message to send
        """
        try:
            # Serialize message
            content = json.dumps(message, separators=(',', ':'))
            content_bytes = content.encode('utf-8')
            
            # Write headers
            header = f"Content-Length: {len(content_bytes)}\r\n\r\n"
            stream.write(header.encode('utf-8'))
            
            # Write body
            stream.write(content_bytes)
            stream.flush()
            
        except Exception as e:
            logger.error(f"Error writing message: {e}")
    
    def process_message(self, message: Dict, direction: str) -> Dict:
        """
        Process a message, rewriting paths as needed.
        
        Args:
            message: The message to process
            direction: Either "to_container" or "to_host"
            
        Returns:
            The processed message
        """
        if direction == "to_container":
            from_prefix, to_prefix = HOST_ROOT, CONTAINER_ROOT
        else:
            from_prefix, to_prefix = CONTAINER_ROOT, HOST_ROOT
        
        # Log the message type for debugging
        method = message.get("method", "")
        if method and logger.isEnabledFor(logging.DEBUG):
            logger.debug(f"{direction}: {method}")
        
        # Rewrite paths in the message
        return self.rewriter.rewrite_object(message, from_prefix, to_prefix)
    
    def run(self) -> None:
        """Main proxy loop."""
        logger.info("Starting proxy loop")
        
        try:
            while self.running:
                # Read message from client (Neovim)
                client_msg = self.read_message(sys.stdin.buffer)
                if client_msg is None:
                    logger.info("Client disconnected")
                    break
                
                # Process and forward to server
                server_msg = self.process_message(client_msg, "to_container")
                self.write_message(self.child.stdin, server_msg)
                
                # For requests, wait for response
                if "id" in client_msg:
                    # This is a request, expect a response
                    server_response = self.read_message(self.child.stdout)
                    if server_response is None:
                        logger.warning("Server disconnected while waiting for response")
                        break
                    
                    # Process and forward response to client
                    client_response = self.process_message(server_response, "to_host")
                    self.write_message(sys.stdout.buffer, client_response)
                
                # Also handle any notifications from server
                # (This is a simplified approach; a full implementation would need
                # better async handling)
                
        except KeyboardInterrupt:
            logger.info("Interrupted by user")
        except Exception as e:
            logger.error(f"Unexpected error in proxy loop: {e}\n{traceback.format_exc()}")
        finally:
            self.shutdown()
    
    def shutdown(self) -> None:
        """Clean shutdown of the proxy."""
        logger.info("Shutting down proxy")
        self.running = False
        
        if self.child:
            try:
                # Try graceful shutdown first
                self.child.terminate()
                self.child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Force kill if needed
                self.child.kill()
                self.child.wait()
            except Exception as e:
                logger.error(f"Error during shutdown: {e}")
        
        logger.info("Proxy shutdown complete")


def main():
    """Main entry point."""
    logger.info("=" * 60)
    logger.info("Pyright Path Translation Shim Starting")
    logger.info(f"Python version: {sys.version}")
    logger.info(f"Host root: {HOST_ROOT}")
    logger.info(f"Container root: {CONTAINER_ROOT}")
    logger.info("=" * 60)
    
    proxy = JsonRpcProxy()
    proxy.run()


if __name__ == "__main__":
    main()
