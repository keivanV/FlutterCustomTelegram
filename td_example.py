import json
import os
import sys
import asyncio
import logging
import glob
import time
import urllib.parse
import base64
from pydub import AudioSegment

from ctypes import CDLL, CFUNCTYPE, c_char_p, c_double, c_int
from ctypes.util import find_library
from typing import Any, Dict, Optional, List
import hashlib
from utils import generate_waveform, convert_oga_to_wav
from config import BACKEND_HOST

logger = logging.getLogger(__name__)

class TdExample:
    def __init__(self, session_path: str, api_id: int, api_hash: str):
        """Initialize TDLib client."""
        self.api_id = api_id
        self.api_hash = api_hash
        self.use_test_dc = False
        self.session_path = session_path
        self.file_url_cache = {}
        self.chat_cache = {}
        self.sent_message_ids = set()
        os.makedirs(self.session_path, exist_ok=True)
        os.makedirs(os.path.join(self.session_path, "voice"), exist_ok=True)
        self._load_library()
        self._setup_functions()
        self._setup_logging()
        self.client_id = self._td_create_client_id()
        logger.info(f"Created client with ID: {self.client_id} for session: {session_path}")

    def _load_library(self) -> None:
        """Load TDLib library."""
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
        """Configure TDLib function bindings."""
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
        self._td_set_log_message_callback.argtypes = [c_int, self.log_message_callback_type]

    def _setup_logging(self, verbosity_level: int = 1) -> None:
        """Set up TDLib logging."""
        @self.log_message_callback_type
        def on_log_message_callback(verbosity_level, message):
            decoded_message = message.decode('utf-8')
            if verbosity_level == 0:
                logger.error(f"TDLib fatal error: {decoded_message}")
            else:
                logger.info(f"TDLib log: {decoded_message}")

        self._td_set_log_message_callback(2, on_log_message_callback)
        self.execute({"@type": "setLogVerbosityLevel", "new_verbosity_level": verbosity_level})

    def clean_old_voice_files(self) -> None:
        """Remove voice files older than 24 hours."""
        voice_dir = os.path.join(self.session_path, "voice")
        if os.path.exists(voice_dir):
            for file_path in glob.glob(os.path.join(voice_dir, "*.wav")) + glob.glob(os.path.join(voice_dir, "*.oga")):
                try:
                    if os.path.isfile(file_path):
                        file_age = time.time() - os.path.getmtime(file_path)
                        if file_age > 24 * 3600:
                            os.remove(file_path)
                            logger.info(f"Deleted old voice file: {file_path}")
                except Exception as e:
                    logger.warning(f"Failed to delete old voice file {file_path}: {e}")

    def execute(self, query: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Execute a TDLib query synchronously."""
        query_json = json.dumps(query).encode("utf-8")
        result = self._td_execute(query_json)
        if result:
            return json.loads(result.decode("utf-8"))
        return None

    def send(self, query: Dict[str, Any]) -> None:
        """Send a TDLib query asynchronously."""
        logger.info(f"Sending query to TDLib: {query}")
        query_json = json.dumps(query).encode("utf-8")
        self._td_send(self.client_id, query_json)

    async def receive(self, timeout: float = 2.0) -> Optional[Dict[str, Any]]:
        """Receive a TDLib event."""
        try:
            result = self._td_receive(timeout)
            if result:
                return json.loads(result.decode("utf-8"))
        except Exception as e:
            logger.error(f"Error receiving TDLib event: {e}")
        return None

    async def _receive_events(self, timeout: float = 5.0):
        """Generator for receiving TDLib events."""
        end_time = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < end_time:
            try:
                event = await self.receive(timeout=0.5)
                if event:
                    logger.info(f"Received event: {event['@type']}")
                    yield event
            except Exception as e:
                logger.error(f"Error in _receive_events: {e}")
                await asyncio.sleep(0.1)
            await asyncio.sleep(0.05)
        logger.info("No more events received within timeout")

    def destroy_client(self) -> None:
        """Destroy the TDLib client."""
        self.send({"@type": "close"})
        logger.info(f"Destroying client with ID: {self.client_id}")
        for _ in range(5):
            result = self._td_receive(2.0)
            if result and json.loads(result.decode("utf-8")).get("@type") == "updateAuthorizationState":
                auth_state = json.loads(result.decode("utf-8"))["authorization_state"]["@type"]
                if auth_state == "authorizationStateClosed":
                    logger.info(f"Client {self.client_id} closed successfully")
                    break
        self.client_id = 0

    async def check_session(self) -> Dict[str, Any]:
        """Check the authentication state of the session."""
        max_retries = 3
        for attempt in range(max_retries):
            logger.info(f"Checking session, attempt {attempt + 1}")
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
                elif event["@type"] == "error":
                    logger.error(f"TDLib error during session check: {event}")
                    if attempt < max_retries - 1:
                        logger.info("Retrying session check after error")
                        self.destroy_client()
                        self.client_id = self._td_create_client_id()
                        logger.info(f"Recreated client with ID: {self.client_id}")
                        await asyncio.sleep(1.0)
                        break
        logger.warning("No authorization state received after retries")
        return {"is_authenticated": False, "auth_state": "unknown"}

    async def authenticate(self, phone_number: str = None, code: str = None, password: str = None,
                         first_name: str = None, last_name: str = None, email: str = None,
                         email_code: str = None) -> Dict[str, Any]:
        """Authenticate the client with provided credentials."""
        logger.info(f"Authenticate called with phone: {phone_number}, code: {code}")
        
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
                        logger.info("Session closed, recreating client")
                        self.destroy_client()
                        self.client_id = self._td_create_client_id()
                        logger.info(f"Recreated client with ID: {self.client_id}")
                        return {"status": "closed"}
            await asyncio.sleep(1)
        logger.warning("No authorization state received after retries")
        return {"status": "unknown"}

    async def download_file(self, file_id: int, phone_number: str, retries: int = 5, timeout: float = 15.0) -> Optional[str]:
        """Download a file and return its URL."""
        if file_id in self.file_url_cache:
            logger.info(f"Returning cached URL for file_id: {file_id}")
            return self.file_url_cache[file_id] if self.file_url_cache[file_id] else None
        
        session_id = hashlib.md5(phone_number.encode()).hexdigest()
        voice_dir = os.path.join(self.session_path, "voice")
        os.makedirs(voice_dir, exist_ok=True)
        for attempt in range(retries):
            logger.info(f"Attempt {attempt + 1} to download file_id: {file_id} for phone: {phone_number}")
            self.send({"@type": "getFile", "file_id": file_id})
            download_initiated = False
            async for event in self._receive_events(timeout=timeout):
                if event["@type"] == "file" and event["id"] == file_id:
                    local = event.get("local", {})
                    if local.get("is_downloading_completed", False) and local.get("path"):
                        if not os.path.exists(local["path"]):
                            logger.warning(f"File path {local['path']} does not exist, skipping")
                            self.file_url_cache[file_id] = None
                            return None
                        oga_path = local["path"]
                        file_name = os.path.basename(oga_path)
                        wav_file_name = file_name.replace(".oga", ".wav") if file_name.endswith(".oga") else f"voice_{file_id}.wav"
                        wav_path = os.path.join(voice_dir, wav_file_name)
                        
                        try:
                            convert_oga_to_wav(oga_path, wav_path)
                        except Exception as e:
                            logger.error(f"Conversion failed for file_id {file_id}: {e}")
                            self.file_url_cache[file_id] = None
                            return None
                        
                        file_url = f"{BACKEND_HOST}/files/{session_id}/voice/{urllib.parse.quote(wav_file_name)}?phone_number={urllib.parse.quote(phone_number)}"
                        self.file_url_cache[file_id] = file_url
                        logger.info(f"Successfully retrieved file URL for file_id: {file_id}: {file_url}")
                        return file_url
                    elif not local.get("is_downloading_active", False) and not local.get("is_downloading_completed", False):
                        if not download_initiated:
                            logger.info(f"Initiating download for file_id: {file_id} on attempt {attempt + 1}")
                            self.send({
                                "@type": "downloadFile",
                                "file_id": file_id,
                                "priority": 1,
                                "offset": 0,
                                "limit": 0,
                                "synchronous": True
                            })
                            download_initiated = True
                    else:
                        logger.debug(f"File_id: {file_id} still downloading or no path on attempt {attempt + 1}")
                elif event["@type"] == "error" and event.get("code") == 404:
                    logger.warning(f"File_id {file_id} not found, skipping")
                    self.file_url_cache[file_id] = None
                    return None
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in download_file: {event}")
                    self.file_url_cache[file_id] = None
                    return None
            await asyncio.sleep(1.0)
        logger.error(f"Failed to get valid URL for file_id: {file_id} after {retries} attempts")
        self.file_url_cache[file_id] = None
        return None

    async def _batch_download_files(self, file_ids: List[tuple], phone_number: str) -> Dict[int, Optional[str]]:
        """Download multiple files in batch."""
        file_urls = {}
        tasks = []
        for file_id, file_type in file_ids:
            if file_id in self.file_url_cache:
                file_urls[file_id] = self.file_url_cache[file_id]
                logger.info(f"Using cached URL for file_id: {file_id} ({file_type})")
            else:
                tasks.append(self.download_file(file_id, phone_number))

        results = await asyncio.gather(*tasks, return_exceptions=True)
        for (file_id, file_type), result in zip(file_ids, results):
            if isinstance(result, Exception):
                logger.error(f"Failed to get file URL for file_id {file_id} ({file_type}): {result}")
                file_urls[file_id] = None
                self.file_url_cache[file_id] = None
            else:
                file_urls[file_id] = result
                logger.info(f"Retrieved URL for file_id: {file_id} ({file_type}): {result}")
        return file_urls

    async def get_chats(self, limit: int = 20, offset: int = 0, phone_number: str = None) -> List[Dict]:
        """Retrieve a list of chats."""
        logger.info(f"Fetching chats with limit={limit}, offset={offset}")
        if offset == 0:
            self.chat_cache.clear()
            logger.info("Cleared chat cache for fresh fetch")

        self.send({
            "@type": "loadChats",
            "chat_list": {"@type": "chatListMain"},
            "limit": limit
        })

        self.send({
            "@type": "getChats",
            "chat_list": {"@type": "chatListMain"},
            "limit": limit,
            "offset_order": "9223372036854775807" if offset == 0 else str(max(
                [self.chat_cache[chat_id]["order"] for chat_id in self.chat_cache if self.chat_cache[chat_id]["order"]] or ["0"]
            )),
            "offset_chat_id": 0 if offset == 0 else max(
                [chat_id for chat_id in self.chat_cache if self.chat_cache[chat_id]["order"]],
                default=0,
                key=lambda x: self.chat_cache[x]["order"] if self.chat_cache[x]["order"] else "0"
            )
        })

        chat_ids = []
        chats = []
        file_ids = []
        timeout = 10.0
        end_time = asyncio.get_event_loop().time() + timeout

        while asyncio.get_event_loop().time() < end_time:
            async for event in self._receive_events(timeout=0.5):
                if event["@type"] == "chats":
                    new_chat_ids = event.get("chat_ids", [])
                    for chat_id in new_chat_ids:
                        if chat_id not in chat_ids:
                            chat_ids.append(chat_id)
                    logger.info(f"Received {len(new_chat_ids)} chat IDs: {new_chat_ids}")
                elif event["@type"] == "updateNewChat":
                    chat = event["chat"]
                    chat_id = chat["id"]
                    last_message = chat.get("last_message")
                    voice_file_id = None
                    waveform = None
                    if last_message and last_message["content"]["@type"] == "messageVoiceNote":
                        voice_file_id = last_message["content"]["voice_note"]["voice"]["id"]
                        waveform = last_message["content"]["voice_note"].get("waveform", "")

                    positions = chat.get("positions", [])
                    order = positions[0].get("order", "0") if positions else "0"

                    self.chat_cache[chat_id] = {
                        "id": chat_id,
                        "title": chat.get("title", "Unknown Chat"),
                        "last_message": last_message,
                        "unread_count": chat.get("unread_count", 0),
                        "voice_file_id": voice_file_id,
                        "waveform": waveform,
                        "order": order
                    }
                    logger.info(f"Updated/Added chat to cache: {chat_id}")
                elif event["@type"] == "updateChatAddedToList":
                    chat_id = event["chat_id"]
                    if chat_id in self.chat_cache and chat_id not in chat_ids:
                        chat_ids.append(chat_id)
                        logger.info(f"Chat {chat_id} added to list via updateChatAddedToList")
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in get_chats: {event}")

        for chat_id in chat_ids:
            if chat_id not in self.chat_cache:
                self.send({"@type": "getChat", "chat_id": chat_id})

        for _ in range(len(chat_ids)):
            async for event in self._receive_events(timeout=1.0):
                if event["@type"] == "chat":
                    chat_id = event["id"]
                    last_message = event.get("last_message")
                    voice_file_id = None
                    waveform = None
                    if last_message and last_message["content"]["@type"] == "messageVoiceNote":
                        voice_file_id = last_message["content"]["voice_note"]["voice"]["id"]
                        waveform = last_message["content"]["voice_note"].get("waveform", "")

                    positions = event.get("positions", [])
                    order = positions[0].get("order", "0") if positions else "0"

                    if chat_id not in self.chat_cache or self.chat_cache[chat_id]["order"] != order:
                        self.chat_cache[chat_id] = {
                            "id": chat_id,
                            "title": event.get("title", "Unknown Chat"),
                            "last_message": last_message,
                            "unread_count": event.get("unread_count", 0),
                            "voice_file_id": voice_file_id,
                            "waveform": waveform,
                            "order": order
                        }
                        logger.info(f"Updated/Fetched details for chat: {chat_id}")
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in get_chat: {event}")

        seen_chat_ids = set()
        for chat_id in chat_ids:
            if chat_id in self.chat_cache and chat_id not in seen_chat_ids:
                chats.append(self.chat_cache[chat_id])
                seen_chat_ids.add(chat_id)
                if self.chat_cache[chat_id]["voice_file_id"]:
                    file_ids.append((self.chat_cache[chat_id]["voice_file_id"], "voice"))

        chats.sort(key=lambda x: int(x["order"] or "0"), reverse=True)
        chats = chats[offset:offset + limit]

        if phone_number:
            file_urls = await self._batch_download_files(file_ids, phone_number)
            for chat in chats:
                if chat["last_message"] and chat["last_message"]["content"]["@type"] == "messageVoiceNote":
                    voice_file_id = chat["voice_file_id"]
                    voice_url = file_urls.get(voice_file_id) if voice_file_id else None
                    waveform = chat["waveform"]
                    if isinstance(waveform, str) and waveform:
                        try:
                            waveform_data = [b / 255.0 for b in base64.b64decode(waveform)]
                            logger.info(f"Decoded waveform for chat {chat['id']}: {waveform_data[:10]}...")
                        except Exception as e:
                            logger.error(f"Failed to decode waveform for chat {chat['id']}: {e}")
                            waveform_data = [0.1] * 60  # Default waveform
                    else:
                        logger.warning(f"No waveform data for chat {chat['id']}, using default")
                        waveform_data = [0.1] * 60  # Default waveform
                    if voice_url:
                        chat["last_message"]["content"] = {
                            "@type": "messageVoiceNote",
                            "text": "[Voice Message]",
                            "voice_note": {
                                "duration": chat["last_message"]["content"]["voice_note"]["duration"],
                                "waveform": waveform_data,
                                "voice": {
                                    **chat["last_message"]["content"]["voice_note"]["voice"],
                                    "remote": {
                                        **chat["last_message"]["content"]["voice_note"]["voice"].get("remote", {}),
                                        "url": voice_url
                                    }
                                }
                            }
                        }
                    else:
                        chat["last_message"]["content"] = {
                            "@type": "messageText",
                            "text": {"@type": "formattedText", "text": "[Voice Message Unavailable]"}
                        }
                    del chat["voice_file_id"]
                    del chat["waveform"]

        logger.info(f"Returning {len(chats)} chats")
        return chats

    async def get_messages(self, chat_id: int, limit: int = 50, from_message_id: int = 0, phone_number: str = None) -> List[Dict]:
        """Retrieve messages from a specific chat."""
        logger.info(f"Fetching messages for chat_id: {chat_id}, limit: {limit}, from_message_id: {from_message_id}")
        messages = []
        file_ids = []
        seen_message_ids = set()
        max_retries = 3
        current_from_message_id = from_message_id

        for attempt in range(max_retries):
            logger.info(f"Attempt {attempt + 1} to fetch messages for chat_id: {chat_id} with from_message_id: {current_from_message_id}")
            self.send({
                "@type": "getChatHistory",
                "chat_id": chat_id,
                "limit": limit,
                "from_message_id": current_from_message_id,
                "offset": 0,
                "only_local": False,
            })
            async for event in self._receive_events(timeout=10.0):
                if event["@type"] == "messages":
                    new_messages = []
                    new_file_ids = []
                    for msg in event.get("messages", []):
                        if msg["id"] not in seen_message_ids:
                            seen_message_ids.add(msg["id"])
                            if msg["content"]["@type"] == "messageText":
                                new_messages.append({
                                    "id": msg["id"],
                                    "content": msg["content"]["text"]["text"],
                                    "isVoice": False,
                                    "voiceUrl": None,
                                    "duration": 0,
                                    "is_outgoing": msg["is_outgoing"],
                                    "date": msg["date"],
                                })
                            elif msg["content"]["@type"] == "messageVoiceNote":
                                voice_file_id = msg["content"]["voice_note"]["voice"]["id"]
                                waveform = msg["content"]["voice_note"].get("waveform", "")
                                duration = msg["content"]["voice_note"].get("duration", 0)
                                new_file_ids.append((voice_file_id, "voice"))
                                waveform_data = []
                                if isinstance(waveform, str) and waveform:
                                    try:
                                        waveform_data = [b / 255.0 for b in base64.b64decode(waveform)]
                                        logger.info(f"Decoded waveform for message {msg['id']}: {waveform_data[:10]}...")
                                    except Exception as e:
                                        logger.error(f"Failed to decode waveform for message {msg['id']}: {e}")
                                        waveform_data = [0.1] * 60  # Default waveform
                                else:
                                    logger.warning(f"No waveform data for message {msg['id']}, using default")
                                    waveform_data = [0.1] * 60  # Default waveform
                                new_messages.append({
                                    "id": msg["id"],
                                    "content": "[Voice Message]",
                                    "isVoice": True,
                                    "voiceUrl": None,
                                    "duration": duration,
                                    "is_outgoing": msg["is_outgoing"],
                                    "date": msg["date"],
                                    "voice_file_id": voice_file_id,
                                    "waveformData": waveform_data,
                                })
                    messages.extend(new_messages)
                    file_ids.extend(new_file_ids)
                    logger.info(f"Received {len(new_messages)} new messages on attempt {attempt + 1}")
                    break
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in get_messages: {event}")
                    break
            if messages or event.get("@type") == "error":
                break
            logger.warning(f"No messages received on attempt {attempt + 1}, retrying with from_message_id: 0")
            current_from_message_id = 0
            await asyncio.sleep(1.0)

        if not messages and attempt == max_retries - 1:
            logger.error(f"Failed to fetch messages for chat_id: {chat_id} after {max_retries} attempts")

        if phone_number:
            file_urls = await self._batch_download_files(file_ids, phone_number)
        else:
            file_urls = {}

        for msg in messages:
            if msg["isVoice"]:
                voice_file_id = msg["voice_file_id"]
                voice_url = file_urls.get(voice_file_id) if voice_file_id else None
                msg["voiceUrl"] = voice_url
                logger.info(f"Message {msg['id']} waveformData: {msg['waveformData'][:10]}...")
                del msg["voice_file_id"]

        logger.info(f"Returning {len(messages)} messages for chat_id: {chat_id}")
        return messages

    async def send_message(self, chat_id: int, text: str) -> Dict[str, Any]:
        """Send a text message to a specific chat."""
        self.send({
            "@type": "sendMessage",
            "chat_id": chat_id,
            "input_message_content": {
                "@type": "inputMessageText",
                "text": {"@type": "formattedText", "text": text},
            },
        })
        message_id = None
        async for event in self._receive_events(timeout=5.0):
            if event["@type"] == "message" and event["chat_id"] == chat_id:
                if message_id is None and event["id"] not in self.sent_message_ids:
                    message_id = event["id"]
                    self.sent_message_ids.add(message_id)
                    return {
                        "id": event["id"],
                        "content": event["content"]["text"]["text"],
                        "isVoice": False,
                        "voiceUrl": None,
                        "duration": 0,
                        "is_outgoing": event["is_outgoing"],
                        "date": event["date"],
                    }
                else:
                    logger.info(f"Ignoring duplicate message event for message_id: {event['id']}")
            elif event["@type"] == "error":
                logger.error(f"TDLib error in send_message: {event}")
                return {"status": "error", "message": f"TDLib error: {event['message']}"}
        logger.error("Failed to send message: No valid message event received")
        return {"status": "error", "message": "Failed to send message"}

    async def send_voice_message(self, chat_id: int, voice_path: str, duration: int, phone_number: str) -> Dict[str, Any]:
        """Send a voice message to a specific chat."""
        try:
            if not os.path.exists(voice_path):
                logger.error(f"File does not exist: {voice_path}")
                return {"status": "error", "message": f"File not found: {voice_path}"}

            with open(voice_path, 'rb') as f:
                header = f.read(4)
                logger.info(f"File header: {header.hex()}")
                if header != b'RIFF':
                    logger.error("File is not WAV")
                    return {"status": "error", "message": "File must be WAV"}

            session = hashlib.md5(phone_number.encode()).hexdigest()
            voice_dir = os.path.join(self.session_path, "voice")
            os.makedirs(voice_dir, exist_ok=True)

            # Trim the initial 100ms of the voice file to remove noise
            trimmed_wav_path = voice_path.replace(".wav", "_trimmed.wav")
            try:
                audio = AudioSegment.from_file(voice_path, format="wav")
                audio = audio[100:]  # Trim first 100ms
                audio = audio.set_channels(1).set_sample_width(2).set_frame_rate(16000)
                audio.export(trimmed_wav_path, format="wav")
                logger.info(f"Trimmed {voice_path} to {trimmed_wav_path}")
            except Exception as e:
                logger.error(f"Failed to trim WAV file: {e}")
                return {"status": "error", "message": f"Failed to trim WAV file: {str(e)}"}

            oga_path = trimmed_wav_path.replace(".wav", ".oga")
            try:
                convert_oga_to_wav(trimmed_wav_path, oga_path, reverse=True)
                logger.info(f"Converted {trimmed_wav_path} to {oga_path}")
            except Exception as e:
                logger.error(f"Failed to convert WAV to OGG: {e}")
                return {"status": "error", "message": f"Failed to convert WAV to OGG: {str(e)}"}

            waveform = generate_waveform(trimmed_wav_path)
            if not waveform:
                logger.warning(f"Waveform generation failed for {trimmed_wav_path}, using default")
                waveform = [0.1] * 60  # Default waveform
            logger.info(f"Generated waveform for {trimmed_wav_path}: {waveform[:10]}...")

            # Encode waveform for TDLib
            waveform_encoded = base64.b64encode(
                bytes([int(x * 31) for x in waveform])  # TDLib expects 5-bit values (0-31)
            ).decode('utf-8')

            self.send({
                "@type": "sendMessage",
                "chat_id": chat_id,
                "input_message_content": {
                    "@type": "inputMessageVoiceNote",
                    "voice_note": {
                        "@type": "inputFileLocal",
                        "path": oga_path
                    },
                    "duration": max(0, duration - 1),  # Adjust duration for trimmed portion
                    "waveform": waveform_encoded
                }
            })

            message_id = None
            file_id = None
            file_uploaded = False
            timeout = 30.0
            end_time = asyncio.get_event_loop().time() + timeout

            async for event in self._receive_events(timeout=timeout):
                logger.info(f"Processing event: {event['@type']}")
                if event["@type"] == "message" and event["chat_id"] == chat_id:
                    if message_id is None and event["id"] not in self.sent_message_ids:
                        message_id = event["id"]
                        self.sent_message_ids.add(message_id)
                        if event["content"]["@type"] != "messageVoiceNote":
                            logger.error(f"Unexpected content type: {event['content']['@type']}")
                            return {"status": "error", "message": f"Unexpected content type: {event['content']['@type']}"}
                        voice_note = event["content"]["voice_note"]
                        file_id = voice_note["voice"]["id"]
                        event_waveform = voice_note.get("waveform", "")
                        event_waveform_data = []
                        if isinstance(event_waveform, str) and event_waveform:
                            try:
                                event_waveform_data = [b / 31.0 for b in base64.b64decode(event_waveform)]
                                logger.info(f"TDLib returned waveform for message {message_id}: {event_waveform_data[:10]}...")
                            except Exception as e:
                                logger.error(f"Failed to decode TDLib waveform for message {message_id}: {e}")
                                event_waveform_data = waveform  # Fallback to generated waveform
                        else:
                            logger.warning(f"No waveform returned by TDLib for message {message_id}, using generated")
                            event_waveform_data = waveform
                        logger.info(f"Message sent with ID: {message_id}, file_id: {file_id}")
                elif event["@type"] == "updateFile" and file_id and event["file"]["id"] == file_id:
                    local = event["file"].get("local", {})
                    if local.get("is_downloading_completed", False):
                        file_uploaded = True
                        logger.info(f"File upload completed for file_id: {file_id}")
                        break
                    elif local.get("is_downloading_active", False):
                        logger.info(f"File_id: {file_id} is still uploading")
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in send_voice_message: {event}")
                    return {"status": "error", "message": f"TDLib error: {event['message']}"}

            if message_id is None:
                logger.error("Failed to send voice message: No valid message event received")
                return {"status": "error", "message": "Failed to send voice message"}

            if file_id and file_uploaded:
                file_url = await self.download_file(file_id, phone_number, retries=5, timeout=15.0)
                if not file_url:
                    logger.error(f"Failed to get file URL for file_id: {file_id}")
                    return {
                        "id": message_id,
                        "content": "[Voice Message Pending]",
                        "isVoice": True,
                        "voiceUrl": "",
                        "duration": max(0, duration - 1),
                        "is_outgoing": True,
                        "date": int(time.time()),
                        "waveformData": waveform
                    }

                self.file_url_cache[file_id] = file_url

                response = {
                    "id": message_id,
                    "content": "[Voice Message]",
                    "isVoice": True,
                    "voiceUrl": file_url,
                    "duration": max(0, duration - 1),
                    "is_outgoing": True,
                    "date": int(time.time()),
                    "waveformData": event_waveform_data
                }
                logger.info(f"Generated response for message {message_id}: {response}")
                return response
            else:
                logger.error("File upload not completed or file_id not received")
                return {
                    "id": message_id,
                    "content": "[Voice Message Pending]",
                    "isVoice": True,
                    "voiceUrl": "",
                    "duration": max(0, duration - 1),
                    "is_outgoing": True,
                    "date": int(time.time()),
                    "waveformData": waveform
                }

        except Exception as e:
            logger.error(f"Error in send_voice_message: {str(e)}")
            return {"status": "error", "message": f"Failed to send voice message: {str(e)}"}