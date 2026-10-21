from fastapi import APIRouter

from core.dependencies import CurrentUser
from features.wallets.wallets_models import Wallet
from features.wallets.wallets_service import WalletsService


router = APIRouter(prefix="/wallets", tags=["wallets"])


@router.get("/me", response_model=list[Wallet])
def list_my_wallets(current_user: CurrentUser) -> list[Wallet]:
    return WalletsService().list_my_wallets(current_user.id)
