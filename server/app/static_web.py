from __future__ import annotations

from pathlib import Path

from starlette.exceptions import HTTPException
from starlette.staticfiles import StaticFiles


class SPAStaticFiles(StaticFiles):
    """Serve static files and fall back to index.html for extensionless pages."""

    async def get_response(self, path: str, scope):
        noindex = _is_admin_path(path)
        try:
            response = await super().get_response(path, scope)
        except HTTPException as exc:
            if exc.status_code == 404 and not Path(path).suffix:
                return _apply_browser_policies(
                    await super().get_response("index.html", scope),
                    noindex=noindex,
                )
            raise
        if response.status_code == 404 and not Path(path).suffix:
            return _apply_browser_policies(
                await super().get_response("index.html", scope),
                noindex=noindex,
            )
        return _apply_browser_policies(response, noindex=noindex)


def _is_admin_path(path: str) -> bool:
    normalized = str(path).strip("/")
    return normalized == "admin" or normalized.startswith("admin/")


def _apply_browser_policies(response, *, noindex: bool = False):
    # Without an explicit policy browsers cache HTML heuristically for hours,
    # so members could miss entry/routing changes; ETag keeps this a cheap 304.
    if response.headers.get("content-type", "").startswith("text/html"):
        response.headers["cache-control"] = "no-cache"
    if noindex:
        # Keep the administrator console out of search results without
        # advertising its location through robots.txt.
        response.headers["x-robots-tag"] = "noindex, nofollow"
    return response
