from datetime import datetime
from decimal import Decimal

from core.models import APIModel


class Wallet(APIModel):
    id: str
    user_id: str
    currency: str
    available_balance: Decimal
    reserved_balance: Decimal
    pending_balance: Decimal
    status: str
    created_at: datetime
    updated_at: datetime
