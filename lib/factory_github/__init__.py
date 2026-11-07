"""Factory GitHub/local backends for statuses, labels, PRs, merge."""
from .client import Backend, get_backend
__all__ = ["Backend", "get_backend"]
