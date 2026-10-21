from typing import Annotated

from fastapi import APIRouter, File, Form, Response, UploadFile, status

from core.dependencies import CurrentUser
from features.users.users_models import UserProfile
from features.users.users_service import UsersService


router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=UserProfile)
def get_my_profile(current_user: CurrentUser) -> UserProfile:
    return UsersService().get_profile(current_user.id)


@router.put("/me/profile", response_model=UserProfile)
async def complete_my_profile(
    current_user: CurrentUser,
    first_name: Annotated[str, Form(min_length=1, max_length=80, alias="firstName")],
    last_name: Annotated[str, Form(min_length=1, max_length=80, alias="lastName")],
    profile_picture: Annotated[UploadFile, File(alias="profilePicture")],
) -> UserProfile:
    service = UsersService()
    content = None
    content_type = None
    maximum = service.settings.profile_picture_max_bytes
    content = await profile_picture.read(maximum + 1)
    content_type = profile_picture.content_type
    return service.complete_profile(
        current_user.id,
        first_name=first_name,
        last_name=last_name,
        picture_content=content,
        picture_content_type=content_type,
    )


@router.patch("/me", response_model=UserProfile)
async def update_my_profile(
    current_user: CurrentUser,
    first_name: Annotated[
        str | None, Form(min_length=1, max_length=80, alias="firstName")
    ] = None,
    last_name: Annotated[
        str | None, Form(min_length=1, max_length=80, alias="lastName")
    ] = None,
    profile_picture: Annotated[
        UploadFile | None, File(alias="profilePicture")
    ] = None,
    remove_profile_picture: Annotated[
        bool, Form(alias="removeProfilePicture")
    ] = False,
) -> UserProfile:
    service = UsersService()
    content = None
    content_type = None
    if profile_picture is not None:
        maximum = service.settings.profile_picture_max_bytes
        content = await profile_picture.read(maximum + 1)
        content_type = profile_picture.content_type
    return service.update_profile(
        current_user.id,
        first_name=first_name,
        last_name=last_name,
        picture_content=content,
        picture_content_type=content_type,
        remove_profile_picture=remove_profile_picture,
    )


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_my_account(current_user: CurrentUser) -> Response:
    UsersService().delete_account(current_user.id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
