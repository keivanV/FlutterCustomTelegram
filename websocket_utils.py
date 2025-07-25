from typing import Dict, List
from fastapi import WebSocket
import json
import logging

logger = logging.getLogger(__name__)

# Shared state for clients and WebSocket connections
clients: Dict[str, 'TdExample'] = {}  # Map phone_number to TdExample instance
websocket_connections: Dict[str, List[WebSocket]] = {}  # Map phone_number to list of WebSocket connections

async def broadcast_message(phone_number: str, message: dict):
    """Broadcast message to all connected WebSocket clients for a phone number."""
    if phone_number in websocket_connections:
        for ws in websocket_connections[phone_number][:]:
            try:
                await ws.send_json(message)
                logger.info(f"Broadcasted message to WebSocket for {phone_number}")
            except WebSocketDisconnect:
                websocket_connections[phone_number].remove(ws)
                logger.info(f"Removed disconnected WebSocket for {phone_number}")
            except Exception as e:
                logger.error(f"Error broadcasting to WebSocket for {phone_number}: {e}")
                websocket_connections[phone_number].remove(ws)
                if not websocket_connections[phone_number]:
                    del websocket_connections[phone_number]