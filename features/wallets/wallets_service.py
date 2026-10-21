from features.wallets.wallets_models import Wallet
from features.wallets.wallets_repository import WalletsRepository


class WalletsService:
    def __init__(self, repository: WalletsRepository | None = None) -> None:
        self.repository = repository or WalletsRepository()

    def list_my_wallets(self, user_id: str) -> list[Wallet]:
        return [Wallet.model_validate(row) for row in self.repository.list_for_user(user_id)]
