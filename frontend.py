#!/usr/bin/env python3
import json
import os
import sys
from PyQt5.QtWidgets import QApplication, QMainWindow, QWidget, QVBoxLayout, QLineEdit, QPushButton, QLabel
from PyQt5.QtCore import QThread, pyqtSignal, Qt
from PyQt5.QtGui import QFont
from queue import Queue, Empty
import time
from ctypes import CDLL, CFUNCTYPE, c_char_p, c_double, c_int
from ctypes.util import find_library
import logging

# Setup logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

class TdExample:
    """A Python client for the Telegram API using TDLib."""
    def __init__(self, api_id: int = None, api_hash: str = None):
        self.api_id = api_id
        self.api_hash = api_hash
        self.tdjson = None
        self._load_library()
        self._setup_functions()
        self.client_id = self._td_create_client_id()

    def _load_library(self) -> None:
        tdjson_path = find_library("tdjson")
        if tdjson_path is None:
            tdjson_path = os.path.join(os.path.dirname(__file__), "td/build/Release/tdjson.dll")
            logging.debug(f"Using fallback tdjson path: {tdjson_path}")
        
        if not os.path.exists(tdjson_path):
            logging.error(f"tdjson library not found at: {tdjson_path}")
            sys.exit(f"Error: tdjson library not found at {tdjson_path}")

        try:
            self.tdjson = CDLL(tdjson_path)
            logging.info(f"Successfully loaded tdjson from: {tdjson_path}")
        except Exception as e:
            logging.error(f"Error loading TDLib: {e}")
            sys.exit(f"Error loading TDLib: {e}")

    def _setup_functions(self) -> None:
        try:
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
        except AttributeError as e:
            logging.error(f"Failed to setup TDLib functions: {e}")
            sys.exit(f"Error: Failed to setup TDLib functions: {e}")

    def execute(self, query: dict) -> dict:
        try:
            query_json = json.dumps(query).encode("utf-8")
            logging.debug(f"Executing query: {query}")
            result = self._td_execute(query_json)
            if result:
                decoded_result = result.decode("utf-8")
                logging.debug(f"Execute result: {decoded_result}")
                return json.loads(decoded_result)
            return None
        except Exception as e:
            logging.error(f"Error executing query: {e}")
            return None

    def send(self, query: dict) -> None:
        try:
            query_json = json.dumps(query).encode("utf-8")
            logging.debug(f"Sending query: {query}")
            self._td_send(self.client_id, query_json)
        except Exception as e:
            logging.error(f"Error sending query: {e}")

    def receive(self, timeout: float = 1.0) -> dict:
        try:
            result = self._td_receive(timeout)
            if result:
                decoded_result = result.decode("utf-8")
                logging.debug(f"Received: {decoded_result}")
                return json.loads(decoded_result)
            return None
        except Exception as e:
            logging.error(f"Error receiving data: {e}")
            return None

class TelegramClientThread(QThread):
    """Thread to run TDLib client event loop and emit events to the UI."""
    event_received = pyqtSignal(dict)

    def __init__(self, client: TdExample):
        super().__init__()
        self.client = client
        self.query_queue = Queue()
        self.running = True

    def send_query(self, query: dict):
        """Add a query to the queue for processing in the client thread."""
        self.query_queue.put(query)

    def run(self):
        # Setup logging in the dedicated thread
        @self.client.log_message_callback_type
        def on_log_message_callback(verbosity_level, message):
            if verbosity_level == 0:
                logging.error(f"TDLib fatal error: {message.decode('utf-8')}")
                sys.exit(f"TDLib fatal error: {message.decode('utf-8')}")
            else:
                logging.debug(f"TDLib log: {message.decode('utf-8')}")

        try:
            self.client._td_set_log_message_callback(2, on_log_message_callback)
            logging.info("Logging callback set successfully")
            result = self.client.execute({"@type": "setLogVerbosityLevel", "new_verbosity_level": 1})
            logging.debug(f"Set log verbosity result: {result}")
        except Exception as e:
            logging.error(f"Error setting up logging: {e}")
            sys.exit(f"Error setting up logging: {e}")

        while self.running:
            # Process queued queries
            try:
                query = self.query_queue.get_nowait()
                self.client.send(query)
            except Empty:
                pass

            # Receive updates
            event = self.client.receive(timeout=1.0)
            if event:
                self.event_received.emit(event)
            time.sleep(0.01)  # Prevent CPU overuse

    def stop(self):
        self.running = False
        self.query_queue.put({"@type": "close"})

class TelegramUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.API_ID = 855178  # Replace with your API ID
        self.API_HASH = "d4b8d0a8494ab6043f0cfdb1ee6383d3"  # Replace with your API Hash
        self.client = None
        self.client_thread = None
        self.setWindowTitle("Telegram Desktop Client")
        self.setGeometry(100, 100, 400, 300)
        self.init_client()

    def init_client(self):
        try:
            self.client = TdExample(self.API_ID, self.API_HASH)
            self.client_thread = TelegramClientThread(self.client)
            self.client_thread.event_received.connect(self.handle_event)
            self.client_thread.start()
            self.client_thread.send_query({"@type": "getAuthorizationState"})
            logging.info("Sent getAuthorizationState query")
        except Exception as e:
            logging.error(f"Error initializing client: {e}")
            sys.exit(f"Error initializing client: {e}")
        self.init_ui()

    def init_ui(self):
        self.central_widget = QWidget()
        self.setCentralWidget(self.central_widget)
        self.main_layout = QVBoxLayout(self.central_widget)
        self.show_login_screen()

    def show_login_screen(self):
        self.login_widget = QWidget()
        self.login_layout = QVBoxLayout(self.login_widget)
        self.login_layout.setAlignment(Qt.AlignCenter)

        self.title_label = QLabel("Telegram Login")
        self.title_label.setFont(QFont("Arial", 18, QFont.Bold))
        self.login_layout.addWidget(self.title_label)

        self.input_field = QLineEdit()
        self.login_layout.addWidget(self.input_field)

        self.submit_button = QPushButton("Next")
        self.submit_button.clicked.connect(self.handle_submit)
        self.login_layout.addWidget(self.submit_button)

        self.status_label = QLabel("Checking authorization...")
        self.login_layout.addWidget(self.status_label)

        self.main_layout.addWidget(self.login_widget)

    def handle_submit(self):
        if self.auth_state == "authorizationStateWaitPhoneNumber":
            phone_number = self.input_field.text()
            self.client_thread.send_query({"@type": "setAuthenticationPhoneNumber", "phone_number": phone_number})
            self.status_label.setText("Enter Authentication Code")
            self.input_field.clear()

    def handle_event(self, event: dict):
        logging.debug(f"Handling event: {event}")
        if event["@type"] == "updateAuthorizationState":
            auth_state = event["authorization_state"]["@type"]
            self.auth_state = auth_state
            self.status_label.setText(f"Current state: {auth_state}")
            if auth_state == "authorizationStateWaitPhoneNumber":
                self.status_label.setText("Enter Phone Number")

    def closeEvent(self, event):
        if self.client_thread:
            self.client_thread.stop()
        logging.info("Application closing")
        event.accept()

def main():
    app = QApplication(sys.argv)
    ui = TelegramUI()
    ui.show()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()