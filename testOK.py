#!/usr/bin/env python3
import json
import os
import sys
from ctypes import CDLL, CFUNCTYPE, c_char_p, c_double, c_int
from ctypes.util import find_library
from typing import Any, Dict, Optional


class TdExample:
    """A Python client for the Telegram API using TDLib."""

    def __init__(self, api_id: int = None, api_hash: str = None):
        self.api_id = api_id
        self.api_hash = api_hash
        self.use_test_dc = False
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
                sys.exit("Error: Can't find 'tdjson' library.")

        try:
            self.tdjson = CDLL(tdjson_path)
        except Exception as e:
            sys.exit(f"Error loading TDLib: {e}")

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
                sys.exit(f"TDLib fatal error: {message.decode('utf-8')}")

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

    def receive(self, timeout: float = 1.0) -> Optional[Dict[str, Any]]:
        result = self._td_receive(timeout)
        if result:
            return json.loads(result.decode("utf-8"))
        return None

    def login(self) -> None:
        self.send({"@type": "getOption", "name": "version"})

        print("Starting Telegram login...")
        print("Press Ctrl+C to cancel.")

        try:
            self._handle_authentication()
        except KeyboardInterrupt:
            print("\nCanceled by user.")
            sys.exit(0)

    def _handle_authentication(self) -> None:
        while True:
            event = self.receive()
            if not event:
                continue

            if event["@type"] != "updateAuthorizationState":
                print(json.dumps(event, indent=2))

            if event["@type"] == "updateAuthorizationState":
                auth_state = event["authorization_state"]
                auth_type = auth_state["@type"]
                print(f"Current state: {auth_type}")

                if auth_type == "authorizationStateClosed":
                    print("Authorization state closed.")
                    break

                elif auth_type == "authorizationStateWaitTdlibParameters":
                    if not self.api_id or not self.api_hash:
                        print("You need to provide your API ID and API Hash.")
                        self.api_id = int(input("API ID: "))
                        self.api_hash = input("API Hash: ")

                    print("Sending TDLib parameters...")
                    self.send({
                        "@type": "setTdlibParameters",
                        "use_test_dc": self.use_test_dc,
                        "database_directory": "tdlib_data",
                        "use_message_database": True,
                        "use_secret_chats": False,
                        "api_id": self.api_id,
                        "api_hash": self.api_hash,
                        "system_language_code": "en",
                        "device_model": "Python TDLib Client",
                        "application_version": "1.0",
                        "enable_storage_optimizer": True
                    })

                elif auth_type == "authorizationStateWaitPhoneNumber":
                    phone_number = input("Phone number: ")
                    self.send({
                        "@type": "setAuthenticationPhoneNumber",
                        "phone_number": phone_number,
                    })

                elif auth_type == "authorizationStateWaitCode":
                    code = input("Authentication code: ")
                    self.send({"@type": "checkAuthenticationCode", "code": code})

                elif auth_type == "authorizationStateWaitPassword":
                    password = input("Password (2FA): ")
                    self.send({
                        "@type": "checkAuthenticationPassword",
                        "password": password,
                    })

                elif auth_type == "authorizationStateWaitRegistration":
                    first_name = input("First name: ")
                    last_name = input("Last name: ")
                    self.send({
                        "@type": "registerUser",
                        "first_name": first_name,
                        "last_name": last_name,
                    })

                elif auth_type == "authorizationStateWaitEmailAddress":
                    email = input("Email address: ")
                    self.send({
                        "@type": "setAuthenticationEmailAddress",
                        "email_address": email,
                    })

                elif auth_type == "authorizationStateWaitEmailCode":
                    email_code = input("Email code: ")
                    self.send({
                        "@type": "checkAuthenticationEmailCode",
                        "code": {
                            "@type": "emailAddressAuthenticationCode",
                            "code": email_code,
                        },
                    })

                elif auth_type == "authorizationStateWaitPremiumPurchase":
                    print("Telegram Premium subscription is required.")
                    return

                elif auth_type == "authorizationStateReady":
                    print("✅ Authorization complete!")
                    return


def main():
    DEFAULT_API_ID = 855178
    DEFAULT_API_HASH = "d4b8d0a8494ab6043f0cfdb1ee6383d3"

    print("TDLib Python Client")
    print("===================")
    print("Use default API credentials? (y/n): ", end="")
    use_default = input().lower() == "y"

    if use_default:
        client = TdExample(DEFAULT_API_ID, DEFAULT_API_HASH)
    else:
        client = TdExample()

    print("\nTesting `execute` method...")
    result = client.execute({
        "@type": "getTextEntities",
        "text": "@telegram /test_command https://telegram.org telegram.me",
    })
    print("Text entities result:")
    print(json.dumps(result, indent=2))

    client.login()

    print("\nEntering main event loop. Press Ctrl+C to exit.")
    try:
        while True:
            event = client.receive()
            if event:
                print(json.dumps(event, indent=2))
    except KeyboardInterrupt:
        print("\nExited.")


if __name__ == "__main__":
    main()
