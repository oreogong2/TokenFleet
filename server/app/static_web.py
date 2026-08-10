from __future__ import annotations

from pathlib import Path

from starlette.exceptions import HTTPException
from starlette.staticfiles import StaticFiles


class SPAStaticFiles(StaticFiles):
    """Serve static files and fall back to index.html for extensionless pages."""

    async def get_response(self, path: str, scope):
        try:
            response = await super().get_response(path, scope)
        except HTTPException as exc:
            if exc.status_code == 404 and not Path(path).suffix:
                return await super().get_response("index.html", scope)
            raise
        if response.status_code == 404 and not Path(path).suffix:
            return await super().get_response("index.html", scope)
        return response
