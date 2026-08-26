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
                return _revalidate_html(await super().get_response("index.html", scope))
            raise
        if response.status_code == 404 and not Path(path).suffix:
            return _revalidate_html(await super().get_response("index.html", scope))
        return _revalidate_html(response)


def _revalidate_html(response):
    # Without an explicit policy browsers cache HTML heuristically for hours,
    # so members could miss entry/routing changes; ETag keeps this a cheap 304.
    if response.headers.get("content-type", "").startswith("text/html"):
        response.headers["cache-control"] = "no-cache"
    return response
