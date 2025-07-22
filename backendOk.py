import json
import os
import sys
from ctypes import CDLL, CFUNCTYPE, c_char_p, c_double, c_int
from ctypes.util import find_library
from typing import Any, Dict, Optional
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import asyncio
import uvicorn
import hashlib
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

class TdExample:
    """A Python client for the Telegram API using TDLib."""

    def __init__(self, session_path: str, api_id: int, api_hash: str):
        self.api_id = api_id
        self.api_hash = api_hash
        self.use_test_dc = False
        self.session_path = session_path
        os.makedirs(self.session_path, exist_ok=True)
        self._load_library()
        self._setup_functions()
        self._setup_logging()
        self.client_id = self._td_create_client_id()

    def _load_library(self) -> None:
        tdjson_path = find_library("tdjson")
        if tdjson_path is None:
            if os.name == "nt":
                tdjson_path = os.path.join(os.path.dirname(__file__), "td/build/Release/tdjson.dll")
            else:
                logger.error("Can't find 'tdjson' library.")
                sys.exit(1)

        try:
            self.tdjson = CDLL(tdjson_path)
        except Exception as e:
            logger.error(f"Error loading TDLib: {e}")
            sys.exit(1)

    def _setup_functions(self) -> None:
        self._td_create_client_id = self.tdjson.td_create_client_id
        self._td_create_client_id.restype = c_int
        self._td_create_client_id.argtypes = []

        self._td_receive = self.tdjson.td_receive
        self._td_receive.restype = c_char_p
        self._td_receive.argtypes = [c_double]

        self._td_send = self.tdjson.td_send
        self._td_send.restype = None
        self._td_send.argtypes = [c_int, c_char_p]

        self._td_execute = self.tdjson.td_execute
        self._td_execute.restype = c_char_p
        self._td_execute.argtypes = [c_char_p]

        self.log_message_callback_type = CFUNCTYPE(None, c_int, c_char_p)
        self._td_set_log_message_callback = self.tdjson.td_set_log_message_callback
        self._td_set_log_message_callback.restype = None
        self._td_set_log_message_callback.argtypes = [
            c_int,
            self.log_message_callback_type,
        ]

    def _setup_logging(self, verbosity_level: int = 1) -> None:
        @self.log_message_callback_type
        def on_log_message_callback(verbosity_level, message):
            if verbosity_level == 0:
                logger.error(f"TDLib fatal error: {message.decode('utf-8')}")
                sys.exit(1)

        self._td_set_log_message_callback(2, on_log_message_callback)
        self.execute(
            {"@type": "setLogVerbosityLevel", "new_verbosity_level": verbosity_level}
        )

    def execute(self, query: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        query_json = json.dumps(query).encode("utf-8")
        result = self._td_execute(query_json)
        if result:
            return json.loads(result.decode("utf-8"))
        return None

    def send(self, query: Dict[str, Any]) -> None:
        query_json = json.dumps(query).encode("utf-8")
        self._td_send(self.client_id, query_json)

    async def receive(self, timeout: float = 2.0) -> Optional[Dict[str, Any]]:
        result = self._td_receive(timeout)
        if result:
            return json.loads(result.decode("utf-8"))
        return None

    async def check_session(self) -> Dict[str, Any]:
        self.send({"@type": "getAuthorizationState"})
        async for event in self._receive_events(timeout=10.0):
            if event["@type"] == "updateAuthorizationState":
                auth_state = event["authorization_state"]["@type"]
                logger.info(f"Session check state: {auth_state}")
                if auth_state == "authorizationStateWaitTdlibParameters":
                    self.send({
                        "@type": "setTdlibParameters",
                        "use_test_dc": self.use_test_dc,
                        "database_directory": self.session_path,
                        "use_message_database": True,
                        "use_secret_chats": False,
                        "api_id": self.api_id,
                        "api_hash": self.api_hash,
                        "system_language_code": "en",
                        "device_model": "Python TDLib Client",
                        "application_version": "1.0",
                        "enable_storage_optimizer": True
                    })
                    async for next_event in self._receive_events(timeout=10.0):
                        if next_event["@type"] == "updateAuthorizationState":
                            auth_state = next_event["authorization_state"]["@type"]
                            logger.info(f"Session check after parameters: {auth_state}")
                            return {
                                "is_authenticated": auth_state == "authorizationStateReady",
                                "auth_state": auth_state
                            }
                return {
                    "is_authenticated": auth_state == "authorizationStateReady",
                    "auth_state": auth_state
                }
        return {"is_authenticated": False, "auth_state": "unknown"}

    async def authenticate(self, phone_number: str = None, code: str = None, password: str = None,
                         first_name: str = None, last_name: str = None, email: str = None,
                         email_code: str = None) -> Dict[str, Any]:
        logger.info(f"Authenticate called with phone: {phone_number}, code: {code}, password: {password}, "
                   f"first_name: {first_name}, last_name: {last_name}, email: {email}, email_code: {email_code}")
        
        if not any([phone_number, code, password, first_name, last_name, email, email_code]):
            self.send({"@type": "getAuthorizationState"})

        if phone_number:
            self.send({
                "@type": "setAuthenticationPhoneNumber",
                "phone_number": phone_number,
                "settings": {
                    "@type": "phoneNumberAuthenticationSettings",
                    "allow_sms": True,
                    "allow_flash_call": False,
                    "is_current_phone_number": True
                }
            })
        if code:
            self.send({"@type": "checkAuthenticationCode", "code": code})
        if password:
            self.send({"@type": "checkAuthenticationPassword", "password": password})
        if first_name and last_name:
            self.send({"@type": "registerUser", "first_name": first_name, "last_name": last_name})
        if email:
            self.send({"@type": "setAuthenticationEmailAddress", "email_address": email})
        if email_code:
            self.send({
                "@type": "checkAuthenticationEmailCode",
                "code": {"@type": "emailAddressAuthenticationCode", "code": email_code},
            })

        for _ in range(3):
            async for event in self._receive_events(timeout=10.0):
                if event["@type"] == "updateAuthorizationState":
                    auth_state = event["authorization_state"]
                    auth_type = auth_state["@type"]
                    logger.info(f"Auth state: {auth_type}")
                    if auth_type == "authorizationStateReady":
                        return {"status": "authenticated"}
                    elif auth_type == "authorizationStateWaitTdlibParameters":
                        self.send({
                            "@type": "setTdlibParameters",
                            "use_test_dc": self.use_test_dc,
                            "database_directory": self.session_path,
                            "use_message_database": True,
                            "use_secret_chats": False,
                            "api_id": self.api_id,
                            "api_hash": self.api_hash,
                            "system_language_code": "en",
                            "device_model": "Python TDLib Client",
                            "application_version": "1.0",
                            "enable_storage_optimizer": True
                        })
                        return {"status": "parameters_set"}
                    elif auth_type == "authorizationStateWaitPhoneNumber":
                        return {"status": "wait_phone"}
                    elif auth_type == "authorizationStateWaitCode":
                        return {"status": "wait_code"}
                    elif auth_type == "authorizationStateWaitPassword":
                        return {"status": "wait_password"}
                    elif auth_type == "authorizationStateWaitRegistration":
                        return {"status": "wait_registration"}
                    elif auth_type == "authorizationStateWaitEmailAddress":
                        return {"status": "wait_email"}
                    elif auth_type == "authorizationStateWaitEmailCode":
                        return {"status": "wait_email_code"}
                    elif auth_type == "authorizationStateWaitPremiumPurchase":
                        return {"status": "wait_premium"}
                    elif auth_type == "authorizationStateClosed":
                        return {"status": "closed"}
            await asyncio.sleep(1)
        logger.warning("No authorization state received after retries")
        return {"status": "unknown"}

    async def get_chats(self, limit: int = 20) -> list:
        self.send({
            "@type": "getChats",
            "chat_list": {"@type": "chatListMain"},
            "limit": limit
        })
        chat_ids = []
        async for event in self._receive_events(timeout=10.0):
            if event["@type"] == "chats":
                chat_ids = event.get("chat_ids", [])
                break

        # Fetch detailed chat information
        chats = []
        for chat_id in chat_ids:
            self.send({"@type": "getChat", "chat_id": chat_id})
            async for event in self._receive_events(timeout=5.0):
                if event["@type"] == "chat":
                    chats.append({
                        "id": event["id"],
                        "title": event.get("title", "Unknown Chat"),
                        "last_message": event.get("last_message", None)
                    })
                    break
        return chats

    async def _receive_events(self, timeout: float = 10.0):
        end_time = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < end_time:
            event = await self.receive(timeout=2.0)
            if event:
                logger.info(f"Received event: {event}")
                yield event
            await asyncio.sleep(0.1)
        logger.info("No more events received within timeout")

class AuthRequest(BaseModel):
    phone_number: Optional[str] = None
    code: Optional[str] = None
    password: Optional[str] = None
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: Optional[str] = None
    email_code: Optional[str] = None

class SessionRequest(BaseModel):
    phone_number: str

# Store clients by session ID
clients: Dict[str, TdExample] = {}

def get_session_path(phone_number: str) -> str:
    if not phone_number:
        logger.error("Phone number is required for session path")
        raise HTTPException(status_code=422, detail="Phone number is required")
    session_id = hashlib.md5(phone_number.encode()).hexdigest()
    return os.path.join("sessions", session_id)

@app.post("/check_session")
async def check_session(request: SessionRequest):
    logger.info(f"Checking session for phone: {request.phone_number}")
    session_path = get_session_path(request.phone_number)
    if not os.path.exists(session_path):
        logger.info(f"No session found at {session_path}")
        return {"is_authenticated": False, "auth_state": "no_session"}

    client = clients.get(session_path)
    if not client:
        client = TdExample(
            session_path=session_path,
            api_id=855178,  # Replace with your API ID
            api_hash="d4b8d0a8494ab6043f0cfdb1ee6383d3"  # Replace with your API hash
        )
        clients[session_path] = client

    result = await client.check_session()
    logger.info(f"Session check result: {result}")
    return result

@app.post("/authenticate")
async def authenticate(auth: AuthRequest, session: SessionRequest):
    logger.info(f"Authenticate request: auth={auth.model_dump()}, session={session.model_dump()}")
    session_path = get_session_path(session.phone_number)
    os.makedirs(session_path, exist_ok=True)

    client = clients.get(session_path)
    if not client:
        client = TdExample(
            session_path=session_path,
            api_id=855178,  # Replace with your API ID
            api_hash="d4b8d0a8494ab6043f0cfdb1ee6383d3"  # Replace with your API hash
        )
        clients[session_path] = client

    result = await client.authenticate(
        phone_number=auth.phone_number,
        code=auth.code,
        password=auth.password,
        first_name=auth.first_name,
        last_name=auth.last_name,
        email=auth.email,
        email_code=auth.email_code
    )
    logger.info(f"Authenticate result: {result}")
    return result

@app.post("/get_chats")
async def get_chats(session: SessionRequest):
    logger.info(f"Fetching chats for phone: {session.phone_number}")
    session_path = get_session_path(session.phone_number)
    client = clients.get(session_path)
    if not client:
        logger.error("Session not found or invalid")
        raise HTTPException(status_code=400, detail="Session not found or invalid")

    chats = await client.get_chats()
    logger.info(f"Chats fetched: {len(chats)}")
    return {"chats": chats}

if __name__ == "__main__":
    os.makedirs("sessions", exist_ok=True)
    uvicorn.run(app, host="0.0.0.0", port=8000)