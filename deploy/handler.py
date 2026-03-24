"""
RunPod Serverless Handler for Gobii Platform.

Wraps the Django ASGI app so RunPod serverless workers can process
HTTP-like requests. For persistent web serving, use Pod mode instead.
"""
import os
import json
import asyncio

import runpod

# Ensure Django is configured before importing anything
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

import django
django.setup()

from django.test import RequestFactory


def handler(job):
    """
    RunPod serverless handler.

    Expected input format:
    {
        "input": {
            "method": "GET" | "POST" | ...,
            "path": "/api/...",
            "headers": { ... },
            "body": "..." (optional, for POST/PUT/PATCH)
        }
    }

    Or for direct task invocation:
    {
        "input": {
            "action": "health_check" | "run_browser_task" | "list_agents",
            "params": { ... }
        }
    }
    """
    job_input = job.get("input", {})

    # Direct action mode
    action = job_input.get("action")
    if action:
        return handle_action(action, job_input.get("params", {}))

    # HTTP proxy mode
    method = job_input.get("method", "GET").upper()
    path = job_input.get("path", "/healthz/")
    headers = job_input.get("headers", {})
    body = job_input.get("body", "")

    factory = RequestFactory()
    request_method = getattr(factory, method.lower(), factory.get)

    kwargs = {"content_type": headers.get("Content-Type", "application/json")}
    if method in ("POST", "PUT", "PATCH") and body:
        kwargs["data"] = body

    try:
        from django.urls import resolve
        match = resolve(path)
        request = request_method(path, **kwargs)

        for key, value in headers.items():
            header_key = f"HTTP_{key.upper().replace('-', '_')}"
            request.META[header_key] = value

        response = match.func(request, *match.args, **match.kwargs)

        return {
            "status_code": response.status_code,
            "headers": dict(response.items()),
            "body": response.content.decode("utf-8", errors="replace"),
        }
    except Exception as e:
        return {"error": str(e), "status_code": 500}


def handle_action(action, params):
    """Handle direct action invocations."""
    if action == "health_check":
        return {
            "status": "healthy",
            "services": {
                "django": True,
                "redis": _check_redis(),
                "chrome": _check_chrome(),
            }
        }
    elif action == "list_agents":
        from api.models import Agent
        agents = list(Agent.objects.values("id", "name", "status")[:50])
        return {"agents": agents}
    else:
        return {"error": f"Unknown action: {action}"}


def _check_redis():
    try:
        import redis
        r = redis.from_url(os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0"))
        return r.ping()
    except Exception:
        return False


def _check_chrome():
    import shutil
    return shutil.which("google-chrome") is not None


if __name__ == "__main__":
    print("[handler] Starting RunPod serverless handler...")
    runpod.serverless.start({"handler": handler})
