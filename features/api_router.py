from fastapi import APIRouter

from features.auth.auth_route import router as auth_router
from features.bookings.bookings_route import router as bookings_router
from features.catalog.catalog_route import router as catalog_router
from features.conversations.conversations_route import router as conversations_router
from features.disputes.disputes_route import router as disputes_router
from features.favorites.favorites_route import router as favorites_router
from features.listings.listings_route import router as listings_router
from features.notifications.notifications_route import router as notifications_router
from features.payments.payments_route import router as payments_router
from features.reviews.reviews_route import router as reviews_router
from features.shipments.shipments_route import router as shipments_router
from features.trips.trips_route import router as trips_router
from features.users.users_route import router as users_router
from features.wallets.wallets_route import router as wallets_router


api_router = APIRouter()
for router in (
    auth_router,
    users_router,
    catalog_router,
    trips_router,
    listings_router,
    bookings_router,
    shipments_router,
    wallets_router,
    payments_router,
    disputes_router,
    conversations_router,
    notifications_router,
    reviews_router,
    favorites_router,
):
    api_router.include_router(router)
