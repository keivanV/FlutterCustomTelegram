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
        os.makedirs(os.path.join(self.session_path, "profile_photos"), exist_ok=True)
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

    def clean_old_files(self) -> None:
        """Remove voice and profile photo files older than 24 hours."""
        for dir_name in ["voice", "profile_photos"]:
            dir_path = os.path.join(self.session_path, dir_name)
            if os.path.exists(dir_path):
                for file_path in glob.glob(os.path.join(dir_path, "*")):
                    try:
                        if os.path.isfile(file_path):
                            file_age = time.time() - os.path.getmtime(file_path)
                            if file_age > 24 * 3600:
                                os.remove(file_path)
                                logger.info(f"Deleted old file: {file_path}")
                    except Exception as e:
                        logger.warning(f"Failed to delete old file {file_path}: {e}")

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

    async def _receive_events(self, timeout: float = 20.0):
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
        for _ in range(10):
            result = self._td_receive(2.0)
            if result:
                event = json.loads(result.decode("utf-8"))
                if event.get("@type") == "updateAuthorizationState" and event["authorization_state"]["@type"] == "authorizationStateClosed":
                    logger.info(f"Client {self.client_id} closed successfully")
                    break
        self.client_id = 0

    async def check_session(self) -> Dict[str, Any]:
        """Check the authentication state of the session."""
        max_retries = 3
        for attempt in range(max_retries):
            logger.info(f"Checking session, attempt {attempt + 1}")
            self.send({"@type": "getAuthorizationState"})
            async for event in self._receive_events(timeout=20.0):
                logger.info(f"Processing event in check_session: {event['@type']}")
                if event["@type"] == "authorizationStateReady":
                    logger.info("Session is authenticated (authorizationStateReady)")
                    return {"is_authenticated": True, "auth_state": "authenticated"}
                elif event["@type"] == "updateAuthorizationState":
                    auth_state = event["authorization_state"]["@type"]
                    logger.info(f"Session check state: {auth_state}")
                    if auth_state == "authorizationStateReady":
                        logger.info("Session is authenticated via updateAuthorizationState")
                        return {"is_authenticated": True, "auth_state": "authenticated"}
                    elif auth_state == "authorizationStateWaitTdlibParameters":
                        logger.info("Setting TDLib parameters")
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
                    elif auth_state in [
                        "authorizationStateWaitPhoneNumber",
                        "authorizationStateWaitCode",
                        "authorizationStateWaitPassword",
                        "authorizationStateWaitRegistration",
                        "authorizationStateWaitEmailAddress",
                        "authorizationStateWaitEmailCode"
                    ]:
                        logger.info(f"Session requires authentication: {auth_state}")
                        return {"is_authenticated": False, "auth_state": auth_state}
                    elif auth_state == "authorizationStateClosed":
                        logger.info("Session closed, recreating client")
                        self.destroy_client()
                        self.client_id = self._td_create_client_id()
                        logger.info(f"Recreated client with ID: {self.client_id}")
                        break
                elif event["@type"] == "error":
                    logger.error(f"TDLib error during session check: {event}")
                    if attempt < max_retries - 1:
                        logger.info("Retrying session check after error")
                        self.destroy_client()
                        self.client_id = self._td_create_client_id()
                        logger.info(f"Recreated client with ID: {self.client_id}")
                        await asyncio.sleep(1.0)
                        break
            await asyncio.sleep(1.0)
        logger.warning("No valid authorization state received after retries")
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
            async for event in self._receive_events(timeout=20.0):
                if event["@type"] == "updateAuthorizationState":
                    auth_state = event["authorization_state"]
                    auth_type = auth_state["@type"]
                    logger.info(f"Auth state: {auth_type}")
                    if auth_type == "authorizationStateReady":
                        return {"is_authenticated": True, "auth_state": "authenticated"}
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
                        return {"is_authenticated": False, "auth_state": "parameters_set"}
                    elif auth_type == "authorizationStateWaitPhoneNumber":
                        return {"is_authenticated": False, "auth_state": "wait_phone"}
                    elif auth_type == "authorizationStateWaitCode":
                        return {"is_authenticated": False, "auth_state": "wait_code"}
                    elif auth_type == "authorizationStateWaitPassword":
                        return {"is_authenticated": False, "auth_state": "wait_password"}
                    elif auth_type == "authorizationStateWaitRegistration":
                        return {"is_authenticated": False, "auth_state": "wait_registration"}
                    elif auth_type == "authorizationStateWaitEmailAddress":
                        return {"is_authenticated": False, "auth_state": "wait_email"}
                    elif auth_type == "authorizationStateWaitEmailCode":
                        return {"is_authenticated": False, "auth_state": "wait_email_code"}
                    elif auth_type == "authorizationStateWaitPremiumPurchase":
                        return {"is_authenticated": False, "auth_state": "wait_premium"}
                    elif auth_type == "authorizationStateClosed":
                        logger.info("Session closed, recreating client")
                        self.destroy_client()
                        self.client_id = self._td_create_client_id()
                        logger.info(f"Recreated client with ID: {self.client_id}")
                        return {"is_authenticated": False, "auth_state": "closed"}
                elif event["@type"] == "authorizationStateReady":
                    logger.info("Direct authorizationStateReady received during authenticate")
                    return {"is_authenticated": True, "auth_state": "authenticated"}
                elif event["@type"] == "error":
                    logger.error(f"TDLib error during authenticate: {event}")
                    return {"is_authenticated": False, "auth_state": f"error: {event['message']}"}
            await asyncio.sleep(1)
        logger.warning("No authorization state received after retries")
        return {"is_authenticated": False, "auth_state": "unknown"}

    async def download_file(self, file_id: int, phone_number: str, file_type: str = "voice", retries: int = 5, timeout: float = 20.0) -> Optional[str]:
        """Download a file and return its URL."""
        if file_id in self.file_url_cache:
            logger.info(f"Returning cached URL for file_id: {file_id} ({file_type})")
            return self.file_url_cache[file_id] if self.file_url_cache[file_id] else None
        
        session_id = hashlib.md5(phone_number.encode()).hexdigest()
        target_dir = os.path.join(self.session_path, "voice" if file_type == "voice" else "profile_photos")
        os.makedirs(target_dir, exist_ok=True)
        
        for attempt in range(retries):
            logger.info(f"Attempt {attempt + 1} to download file_id: {file_id} ({file_type}) for phone: {phone_number}")
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
                        file_path = local["path"]
                        file_name = os.path.basename(file_path)
                        if file_type == "voice":
                            file_name = file_name.replace(".oga", ".wav") if file_name.endswith(".oga") else f"voice_{file_id}.wav"
                            target_path = os.path.join(target_dir, file_name)
                            try:
                                convert_oga_to_wav(file_path, target_path)
                            except Exception as e:
                                logger.error(f"Conversion failed for file_id {file_id}: {e}")
                                self.file_url_cache[file_id] = None
                                return None
                        else:
                            target_path = os.path.join(target_dir, f"photo_{file_id}_{file_name}")
                            try:
                                os.rename(file_path, target_path)
                            except Exception as e:
                                logger.error(f"Failed to move profile photo for file_id {file_id}: {e}")
                                self.file_url_cache[file_id] = None
                                return None
                        
                        file_url = f"{BACKEND_HOST}/files/{session_id}/{file_type}/{urllib.parse.quote(os.path.basename(target_path))}?phone_number={urllib.parse.quote(phone_number)}"
                        self.file_url_cache[file_id] = file_url
                        logger.info(f"Successfully retrieved file URL for file_id: {file_id} ({file_type}): {file_url}")
                        return file_url
                    elif not local.get("is_downloading_active", False) and not local.get("is_downloading_completed", False):
                        if not download_initiated:
                            logger.info(f"Initiating download for file_id: {file_id} ({file_type}) on attempt {attempt + 1}")
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
                        logger.debug(f"File_id: {file_id} ({file_type}) still downloading or no path on attempt {attempt + 1}")
                elif event["@type"] == "error" and event.get("code") == 404:
                    logger.warning(f"File_id {file_id} ({file_type}) not found, skipping")
                    self.file_url_cache[file_id] = None
                    return None
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in download_file: {event}")
                    self.file_url_cache[file_id] = None
                    return None
            await asyncio.sleep(1.0)
        logger.error(f"Failed to get valid URL for file_id: {file_id} ({file_type}) after {retries} attempts")
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
                tasks.append(self.download_file(file_id, phone_number, file_type))

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
        timeout = 20.0
        end_time = asyncio.get_event_loop().time() + timeout

        while asyncio.get_event_loop().time() < end_time:
            async for event in self._receive_events(timeout=0.5):
                if event["@type"] == "chats":
                    new_chat_ids = event.get("chat_ids", [])
                    for chat_id in new_chat_ids:
                        if chat_id not in chat_ids:
                            chat_ids.append(chat_id)
                            self.send({"@type": "getChat", "chat_id": chat_id})
                    logger.info(f"Received {len(new_chat_ids)} chat IDs: {new_chat_ids}")
                elif event["@type"] == "updateNewChat":
                    chat = event["chat"]
                    chat_id = chat["id"]
                    last_message = chat.get("last_message")
                    voice_file_id = None
                    waveform = None
                    profile_photo_id = None
                    if last_message and last_message["content"]["@type"] == "messageVoiceNote":
                        voice_file_id = last_message["content"]["voice_note"]["voice"]["id"]
                        waveform = last_message["content"]["voice_note"].get("waveform", "")
                    if chat.get("photo"):
                        profile_photo_id = chat["photo"].get("small", {}).get("id")
                    positions = chat.get("positions", [])
                    order = positions[0].get("order", "0") if positions else "0"

                    self.chat_cache[chat_id] = {
                        "id": chat_id,
                        "title": chat.get("title", "Unknown Chat"),
                        "last_message": last_message,
                        "unread_count": chat.get("unread_count", 0),
                        "voice_file_id": voice_file_id,
                        "waveform": waveform,
                        "profile_photo_id": profile_photo_id,
                        "order": order
                    }
                    logger.info(f"Updated/Added chat to cache: {chat_id}")
                elif event["@type"] == "updateChatAddedToList":
                    chat_id = event["chat_id"]
                    if chat_id in self.chat_cache and chat_id not in chat_ids:
                        chat_ids.append(chat_id)
                        self.send({"@type": "getChat", "chat_id": chat_id})
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
                    profile_photo_id = None
                    if last_message and last_message["content"]["@type"] == "messageVoiceNote":
                        voice_file_id = last_message["content"]["voice_note"]["voice"]["id"]
                        waveform = last_message["content"]["voice_note"].get("waveform", "")
                    if event.get("photo"):
                        profile_photo_id = event["photo"].get("small", {}).get("id")

                    positions = event.get("positions", [])
                    order = positions[0].get("order", "0") if positions else "0"

                    if chat_id not in self.chat_cache or self.chat_cache[chat_id]["order"] != order or self.chat_cache[chat_id]["profile_photo_id"] != profile_photo_id:
                        self.chat_cache[chat_id] = {
                            "id": chat_id,
                            "title": event.get("title", "Unknown Chat"),
                            "last_message": last_message,
                            "unread_count": event.get("unread_count", 0),
                            "voice_file_id": voice_file_id,
                            "waveform": waveform,
                            "profile_photo_id": profile_photo_id,
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
                if self.chat_cache[chat_id]["profile_photo_id"]:
                    file_ids.append((self.chat_cache[chat_id]["profile_photo_id"], "profile_photo"))

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
                            waveform_data = [0.1] * 60
                    else:
                        logger.warning(f"No waveform data for chat {chat['id']}, using default")
                        waveform_data = [0.1] * 60
                    if voice_url:
                        chat["last_message"]["content"] = {
                            "@type": "messageVoiceNote",
                            "text": "🔈 پیغام صوتی",
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
                profile_photo_url = file_urls.get(chat["profile_photo_id"]) if chat["profile_photo_id"] else None
                chat["profile_photo_url"] = profile_photo_url
                del chat["voice_file_id"]
                del chat["waveform"]
                del chat["profile_photo_id"]

        logger.info(f"Returning {len(chats)} chats")
        return chats

    async def get_messages(self, chat_id: int, limit: int = 50, from_message_id: int = 0, phone_number: str = None) -> List[Dict]:
        """Retrieve messages from a specific chat."""
        logger.info(f"Fetching messages for chat_id={chat_id}, limit={limit}, from_message_id={from_message_id}")

        # Verify chat existence
        self.send({"@type": "getChat", "chat_id": chat_id})
        chat_exists = False
        async for event in self._receive_events(timeout=5.0):
            if event["@type"] == "chat" and event["id"] == chat_id:
                chat_exists = True
                logger.info(f"Chat {chat_id} exists: {event['title']}")
                break
            elif event["@type"] == "error":
                logger.error(f"Error verifying chat {chat_id}: {event}")
                return []

        if not chat_exists:
            logger.error(f"Chat {chat_id} does not exist or is inaccessible")
            return []

        # Fetch message history
        self.send({
            "@type": "getChatHistory",
            "chat_id": chat_id,
            "limit": limit,
            "from_message_id": from_message_id,
            "offset": 0,
            "only_local": False
        })

        messages = []
        file_ids_to_download = []
        seen_message_ids = set()
        async for event in self._receive_events(timeout=20.0):
            if event["@type"] == "messages":
                logger.info(f"Received messages event with {len(event.get('messages', []))} messages")
                for msg in event.get("messages", []):
                    message_id = msg["id"]
                    if message_id in seen_message_ids:
                        logger.debug(f"Skipping duplicate message ID: {message_id}")
                        continue
                    seen_message_ids.add(message_id)

                    content = msg.get("content", {})
                    content_type = content.get("@type")
                    text = None
                    voice = None
                    duration = 0
                    waveform_data = None
                    status = "success" if message_id in self.sent_message_ids else "success"

                    if content_type == "messageText":
                        text = content.get("text", {}).get("text", "")
                    elif content_type == "messageVoiceNote":
                        voice = content.get("voice_note", {})
                        if voice.get("voice", {}).get("id"):
                            file_ids_to_download.append((voice["voice"]["id"], "voice"))
                        duration = voice.get("duration", 0)
                        waveform = voice.get("waveform", "")
                        if waveform:
                            try:
                                waveform_data = [b / 31.0 for b in base64.b64decode(waveform)]
                            except Exception as e:
                                logger.error(f"Failed to decode waveform for message {message_id}: {e}")
                                waveform_data = [0.1] * 60
                        else:
                            waveform_data = [0.1] * 60
                        text = "🔈 پیغام صوتی"

                    if text:
                        messages.append({
                            "id": message_id,
                            "chat_id": chat_id,
                            "content": text,
                            "is_voice": content_type == "messageVoiceNote",
                            "voice_url": None,
                            "duration": duration,
                            "is_outgoing": msg.get("is_outgoing", False),  # Ensure boolean
                            "date": msg.get("date", 0),
                            "waveform_data": waveform_data,
                            "status": status
                        })
            elif event["@type"] == "error":
                logger.error(f"TDLib error in get_messages: {event}")
                return messages

        # Download voice files if necessary
        if file_ids_to_download and phone_number:
            file_urls = await self._batch_download_files(file_ids_to_download, phone_number)
            for msg in messages:
                if msg["is_voice"] and not msg["voice_url"]:
                    voice_id = next((fid for fid, ftype in file_ids_to_download if ftype == "voice"), None)
                    if voice_id and file_urls.get(voice_id):
                        msg["voice_url"] = file_urls[voice_id]

        messages.sort(key=lambda x: x["date"])
        logger.info(f"Returning {len(messages)} messages for chat_id={chat_id}")
        return messages

    async def send_message(self, chat_id: int, text: str) -> Dict:
        """Send a text message to a specific chat."""
        logger.info(f"Sending message to chat_id={chat_id}, text={text}")
        message_id = None
        self.send({
            "@type": "sendMessage",
            "chat_id": chat_id,
            "input_message_content": {
                "@type": "inputMessageText",
                "text": {"@type": "formattedText", "text": text}
            }
        })

        async for event in self._receive_events(timeout=20.0):
            if event["@type"] == "message":
                if event["chat_id"] == chat_id and event.get("content", {}).get("text", {}).get("text") == text:
                    message_id = event["id"]
                    self.sent_message_ids.add(message_id)
                    return {
                        "id": message_id,
                        "chat_id": chat_id,
                        "content": text,
                        "is_voice": False,
                        "voice_url": None,
                        "duration": 0,
                        "is_outgoing": True,
                        "date": event.get("date", int(time.time())),
                        "waveform_data": None,
                        "status": "success"
                    }
            elif event["@type"] == "error":
                logger.error(f"TDLib error in send_message: {event}")
                return {"status": "error", "message": event["message"]}
        logger.warning("No message event received for send_message")
        return {"status": "error", "message": "No valid message event received"}

    async def send_voice_message(self, chat_id: int, voice_path: str, duration: int, phone_number: str) -> Dict:
        """Send a voice message to a specific chat."""
        logger.info(f"Sending voice message to chat_id={chat_id}, voice_path={voice_path}, duration={duration}")
        if not os.path.exists(voice_path):
            logger.error(f"Voice file not found: {voice_path}")
            return {"status": "error", "message": "Voice file not found"}

        try:
            audio = AudioSegment.from_file(voice_path)
            waveform_data = generate_waveform(voice_path)
            waveform_data = [x * 31 for x in waveform_data]
            waveform_b64 = base64.b64encode(bytes([int(x) for x in waveform_data])).decode("utf-8")

            self.send({
                "@type": "sendMessage",
                "chat_id": chat_id,
                "input_message_content": {
                    "@type": "inputMessageVoiceNote",
                    "voice_note": {
                        "@type": "inputFileLocal",
                        "path": voice_path
                    },
                    "duration": duration,
                    "waveform": waveform_b64
                }
            })

            message_id = None
            async for event in self._receive_events(timeout=20.0):
                if event["@type"] == "message" and event["chat_id"] == chat_id and event.get("content", {}).get("@type") == "messageVoiceNote":
                    message_id = event["id"]
                    voice_id = event["content"]["voice_note"]["voice"]["id"]
                    self.sent_message_ids.add(message_id)
                    voice_url = await self.download_file(voice_id, phone_number, "voice")
                    return {
                        "id": message_id,
                        "chat_id": chat_id,
                        "content": "🔈 پیغام صوتی",
                        "is_voice": True,
                        "voice_url": voice_url,
                        "duration": duration,
                        "is_outgoing": True,
                        "date": event.get("date", int(time.time())),
                        "waveform_data": waveform_data,
                        "status": "success"
                    }
                elif event["@type"] == "error":
                    logger.error(f"TDLib error in send_voice_message: {event}")
                    return {"status": "error", "message": event["message"]}
            logger.warning("No message event received for send_voice_message")
            return {"status": "error", "message": "No valid message event received"}
        except Exception as e:
            logger.error(f"Error processing voice message: {e}")
            return {"status": "error", "message": str(e)}