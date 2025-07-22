from pydantic import BaseModel
from typing import Optional

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

class MessageRequest(BaseModel):
    phone_number: str
    chat_id: int
    limit: int = 50
    from_message_id: int = 0

class SendMessageRequest(BaseModel):
    phone_number: str
    chat_id: int
    message: str

class SendVoiceMessageRequest(BaseModel):
    phone_number: str
    chat_id: int
    duration: int

class GetChatsRequest(BaseModel):
    phone_number: str
    limit: int = 20
    offset: int = 0