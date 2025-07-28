import uvicorn
from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Query, Response
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from models import AuthRequest, SessionRequest, MessageRequest, SendMessageRequest, SendVoiceMessageRequest, GetChatsRequest
from td_example import TdExample
from config import API_ID, API_HASH
from typing import Dict
import json
import logging
import hashlib
import os
import time
import asyncio

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

clients: Dict[str, TdExample] = {}

def get_session_path(phone_number: str) -> str:
    """Generate session path from phone number."""
    if not phone_number:
        logger.error("Phone number is required for session path")
        raise HTTPException(status_code=422, detail="Phone number is required")
    session_id = hashlib.md5(phone_number.encode()).hexdigest()
    return os.path.join("sessions", session_id)

@app.post("/check_session")
async def check_session(request: SessionRequest):
    """Check if a session exists and is authenticated."""
    logger.info(f"Checking session for phone: {request.phone_number}")
    session_path = get_session_path(request.phone_number)
    logger.info(f"Session path: {session_path}")
    if not os.path.exists(session_path):
        logger.info(f"No session found at {session_path}")
        return {"is_authenticated": False, "auth_state": "no_session"}

    client = clients.get(session_path)
    logger.info(f"Client exists: {client is not None}, client_id: {client.client_id if client else 'None'}")
    if not client or client.client_id == 0:
        logger.info(f"Creating new client for session: {session_path}")
        client = TdExample(session_path=session_path, api_id=API_ID, api_hash=API_HASH)
        clients[session_path] = client
        logger.info(f"New client created with client_id: {client.client_id}")

    result = await client.check_session()
    logger.info(f"Session check result: {result}")
    if result["auth_state"] in ["unknown", "authorizationStateClosed"]:
        logger.info(f"Invalid session, destroying client and creating new one for {session_path}")
        client.destroy_client()
        del clients[session_path]
        client = TdExample(session_path=session_path, api_id=API_ID, api_hash=API_HASH)
        clients[session_path] = client
        logger.info(f"New client created with client_id: {client.client_id}")
        result = await client.check_session()
    return result

@app.post("/authenticate")
async def authenticate(request: AuthRequest):
    """Authenticate a client with provided credentials."""
    logger.info(f"Authentication request: phone={request.phone_number}, code={request.code}")
    session_path = get_session_path(request.phone_number)
    logger.info(f"Session path: {session_path}")
    
    client = clients.get(session_path)
    logger.info(f"Client exists: {client is not None}, client_id: {client.client_id if client else 'None'}")
    if not client or client.client_id == 0:
        logger.info(f"Creating new client for authentication: {session_path}")
        client = TdExample(session_path=session_path, api_id=API_ID, api_hash=API_HASH)
        clients[session_path] = client
        logger.info(f"New client created with client_id: {client.client_id}")

    result = await client.authenticate(
        phone_number=request.phone_number,
        code=request.code,
        password=request.password,
        first_name=request.first_name,
        last_name=request.last_name,
        email=request.email,
        email_code=request.email_code
    )
    logger.info(f"Authentication result: {result}")
    return result

@app.post("/get_chats")
async def get_chats(request: GetChatsRequest):
    """Retrieve a list of chats for a given phone number."""
    logger.info(f"Get chats request: phone={request.phone_number}, limit={request.limit}, offset={request.offset}")
    session_path = get_session_path(request.phone_number)
    client = clients.get(session_path)
    if not client or client.client_id == 0:
        logger.error(f"No valid client found for phone: {request.phone_number}")
        raise HTTPException(status_code=401, detail="Client not authenticated")

    chats = await client.get_chats(
        limit=request.limit,
        offset=request.offset,
        phone_number=request.phone_number
    )
    return {"chats": chats}

@app.post("/get_messages")
async def get_messages(request: MessageRequest):
    """Retrieve messages from a specific chat."""
    logger.info(f"Get messages request: phone={request.phone_number}, chat_id={request.chat_id}")
    session_path = get_session_path(request.phone_number)
    client = clients.get(session_path)
    if not client or client.client_id == 0:
        logger.error(f"No valid client found for phone: {request.phone_number}")
        raise HTTPException(status_code=401, detail="Client not authenticated")

    messages = await client.get_messages(
        chat_id=request.chat_id,
        limit=request.limit,
        from_message_id=request.from_message_id,
        phone_number=request.phone_number
    )
    return {"messages": messages}

@app.post("/send_message")
async def send_message(request: SendMessageRequest):
    """Send a text message to a specific chat."""
    logger.info(f"Send message request: phone={request.phone_number}, chat_id={request.chat_id}")
    session_path = get_session_path(request.phone_number)
    client = clients.get(session_path)
    if not client or client.client_id == 0:
        logger.error(f"No valid client found for phone: {request.phone_number}")
        raise HTTPException(status_code=401, detail="Client not authenticated")

    result = await client.send_message(chat_id=request.chat_id, text=request.message)
    return result

@app.post("/send_voice_message")
async def send_voice_message(file: UploadFile = File(...), request: str = Form(...)):
    """Send a voice message to a specific chat."""
    logger.info("Send voice message request received")
    try:
        request_data = json.loads(request)
        phone_number = request_data.get("phone_number")
        chat_id = request_data.get("chat_id")
        duration = request_data.get("duration")
        
        if not phone_number or not chat_id or duration is None:
            logger.error("Missing required fields in send_voice_message request")
            raise HTTPException(status_code=422, detail="Missing required fields: phone_number, chat_id, duration")

        session_path = get_session_path(phone_number)
        client = clients.get(session_path)
        if not client or client.client_id == 0:
            logger.error(f"No valid client found for phone: {phone_number}")
            raise HTTPException(status_code=401, detail="Client not authenticated")

        session_id = hashlib.md5(phone_number.encode()).hexdigest()
        voice_dir = os.path.join(session_path, "voice")
        os.makedirs(voice_dir, exist_ok=True)
        voice_path = os.path.join(voice_dir, f"voice_{int(time.time() * 1000)}.wav")

        with open(voice_path, "wb") as f:
            content = await file.read()
            f.write(content)
        logger.info(f"Saved uploaded voice file to: {voice_path}")

        with open(voice_path, 'rb') as f:
            header = f.read(4)
            if header != b'RIFF':
                logger.error(f"Uploaded file is not WAV: {voice_path}")
                os.remove(voice_path)
                raise HTTPException(status_code=422, detail="File must be WAV")

        result = await client.send_voice_message(
            chat_id=chat_id,
            voice_path=voice_path,
            duration=duration,
            phone_number=phone_number
        )
        return result

    except json.JSONDecodeError:
        logger.error("Invalid JSON in send_voice_message request")
        raise HTTPException(status_code=422, detail="Invalid JSON in request")
    except Exception as e:
        logger.error(f"Error processing send_voice_message: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")

@app.get("/files/{session_id}/{file_type}/{file_name}")
async def get_file(session_id: str, file_type: str, file_name: str, phone_number: str = Query(...)):
    """Serve a file from the session's directory."""
    logger.info(f"File request: session_id={session_id}, file_type={file_type}, file_name={file_name}, phone_number={phone_number}")
    expected_session_id = hashlib.md5(phone_number.encode()).hexdigest()
    if session_id != expected_session_id:
        logger.error(f"Session ID mismatch: {session_id} != {expected_session_id}")
        raise HTTPException(status_code=403, detail="Invalid session ID")

    valid_file_types = {"voice": "voice", "profile_photo": "profile_photos", "profile_photos": "profile_photos"}
    if file_type not in valid_file_types:
        logger.error(f"Invalid file type: {file_type}")
        raise HTTPException(status_code=400, detail="Invalid file type")

    session_path = get_session_path(phone_number)
    file_path = os.path.join(session_path, valid_file_types[file_type], file_name)
    if not os.path.exists(file_path):
        logger.error(f"File not found: {file_path}")
        raise HTTPException(status_code=404, detail="File not found")

    media_type = "audio/wav" if valid_file_types[file_type] == "voice" else "image/jpeg"
    return FileResponse(
        file_path,
        media_type=media_type,
        headers={"Content-Disposition": f"attachment; filename={file_name}"}
    )

@app.head("/files/{session_id}/{file_type}/{file_name}")
async def head_file(session_id: str, file_type: str, file_name: str, phone_number: str = Query(...)):
    """Handle HEAD request for a file."""
    logger.info(f"HEAD request: session_id={session_id}, file_type={file_type}, file_name={file_name}, phone_number={phone_number}")
    expected_session_id = hashlib.md5(phone_number.encode()).hexdigest()
    if session_id != expected_session_id:
        logger.error(f"Session ID mismatch: {session_id} != {expected_session_id}")
        raise HTTPException(status_code=403, detail="Invalid session ID")

    valid_file_types = {"voice": "voice", "profile_photo": "profile_photos", "profile_photos": "profile_photos"}
    if file_type not in valid_file_types:
        logger.error(f"Invalid file type: {file_type}")
        raise HTTPException(status_code=400, detail="Invalid file type")

    session_path = get_session_path(phone_number)
    file_path = os.path.join(session_path, valid_file_types[file_type], file_name)
    if not os.path.exists(file_path):
        logger.error(f"File not found: {file_path}")
        raise HTTPException(status_code=404, detail="File not found")

    file_size = os.path.getsize(file_path)
    media_type = "audio/wav" if valid_file_types[file_type] == "voice" else "image/jpeg"
    return Response(
        headers={
            "Content-Type": media_type,
            "Content-Length": str(file_size),
            "Content-Disposition": f"attachment; filename={file_name}"
        },
        status_code=200
    )

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True, log_level="debug")