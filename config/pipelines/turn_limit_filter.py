"""
title: Conversation Turn Limit Filter
description: Limit conversation turns per user role
"""
from typing import List, Optional
from pydantic import BaseModel

class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 2
        max_turns: int = 10
        target_user_roles: List[str] = ["user", "admin"]

    def __init__(self):
        self.type = "filter"
        self.name = "Turn Limit Filter"
        self.valves = self.Valves()

    async def on_startup(self):
        pass

    async def on_shutdown(self):
        pass

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        if user and user.get("role") in self.valves.target_user_roles:
            turns = len([m for m in body.get("messages", []) if m.get("role") == "user"])
            if turns > self.valves.max_turns:
                raise Exception(f"Conversation limit exceeded ({self.valves.max_turns} turns max)")
        return body
