"""
title: Langfuse Filter Pipeline for v3
author: open-webui
date: 2025-07-31
version: 0.0.1
license: MIT
description: A filter pipeline that uses Langfuse v3.
requirements: langfuse>=3.0.0
"""

from typing import List, Optional
import os
import uuid
import json

from utils.pipelines.main import get_last_assistant_message
from pydantic import BaseModel
from langfuse import Langfuse


def get_last_assistant_message_obj(messages: List[dict]) -> dict:
    """Retrieve the last assistant message from the message list."""
    for message in reversed(messages):
        if message["role"] == "assistant":
            return message
    return {}


class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = ["*"]
        priority: int = 0
        secret_key: str
        public_key: str
        host: str
        insert_tags: bool = True
        use_model_name_instead_of_id_for_generation: bool = False
        debug: bool = False

    def __init__(self):
        self.type = "filter"
        self.name = "Langfuse Filter"

        self.valves = self.Valves(
            **{
                "pipelines": ["*"],
                "secret_key": os.getenv("LANGFUSE_SECRET_KEY", "lf_sk_aiportal_openwebui_secret"),
                "public_key": os.getenv("LANGFUSE_PUBLIC_KEY", "lf_pk_aiportal_openwebui"),
                "host": os.getenv("LANGFUSE_HOST", "https://langfuse.openwebui.demos.apps.equal.expert"),
                "use_model_name_instead_of_id_for_generation": os.getenv("USE_MODEL_NAME", "false").lower() == "true",
                "debug": os.getenv("DEBUG_MODE", "true").lower() == "true",
            }
        )

        self.langfuse = None
        self.chat_traces = {}
        self.suppressed_logs = set()
        self.model_names = {}

    def log(self, message: str, suppress_repeats: bool = False):
        if self.valves.debug:
            if suppress_repeats:
                if message in self.suppressed_logs:
                    return
                self.suppressed_logs.add(message)
            print(f"[DEBUG] {message}")

    async def on_startup(self):
        self.log(f"on_startup triggered for {__name__}")
        self.set_langfuse()

    async def on_shutdown(self):
        self.log(f"on_shutdown triggered for {__name__}")
        if self.langfuse:
            try:
                for chat_id, trace in self.chat_traces.items():
                    try:
                        trace.end()
                        self.log(f"Ended trace for chat_id: {chat_id}")
                    except Exception as e:
                        self.log(f"Failed to end trace for {chat_id}: {e}")

                self.chat_traces.clear()
                self.langfuse.flush()
                self.log("Langfuse data flushed on shutdown")
            except Exception as e:
                self.log(f"Failed to flush Langfuse data: {e}")

    async def on_valves_updated(self):
        self.log("Valves updated, resetting Langfuse client.")
        self.set_langfuse()

    def set_langfuse(self):
        try:
            self.log(f"Initializing Langfuse with host: {self.valves.host}")
            self.log(
                f"Secret key set: {'Yes' if self.valves.secret_key and self.valves.secret_key != 'your-secret-key-here' else 'No'}"
            )
            self.log(
                f"Public key set: {'Yes' if self.valves.public_key and self.valves.public_key != 'your-public-key-here' else 'No'}"
            )

            self.langfuse = Langfuse(
                secret_key=self.valves.secret_key,
                public_key=self.valves.public_key,
                host=self.valves.host,
                debug=self.valves.debug,
            )

            try:
                self.langfuse.auth_check()
                self.log(
                    f"Langfuse client initialized and authenticated successfully. Connected to host: {self.valves.host}")

            except Exception as e:
                self.log(f"Auth check failed: {e}")
                self.log(f"Failed host: {self.valves.host}")
                self.langfuse = None
                return

        except Exception as auth_error:
            if (
                "401" in str(auth_error)
                or "unauthorized" in str(auth_error).lower()
                or "credentials" in str(auth_error).lower()
            ):
                self.log(f"Langfuse credentials incorrect: {auth_error}")
                self.langfuse = None
                return
        except Exception as e:
            self.log(f"Langfuse initialization error: {e}")
            self.langfuse = None

    def _build_tags(self, task_name: str) -> list:
        tags_list = []
        if self.valves.insert_tags:
            tags_list.append("open-webui")
            if task_name not in ["user_response", "llm_response"]:
                tags_list.append(task_name)
        return tags_list

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        self.log("Langfuse Filter INLET called")

        if not self.langfuse:
            self.log("[WARNING] Langfuse client not initialized - Skipped")
            return body

        self.log(f"Inlet function called with body: {body} and user: {user}")

        metadata = body.get("metadata", {})
        chat_id = metadata.get("chat_id", str(uuid.uuid4()))

        if chat_id == "local":
            session_id = metadata.get("session_id")
            chat_id = f"temporary-session-{session_id}"

        metadata["chat_id"] = chat_id
        body["metadata"] = metadata

        model_info = metadata.get("model", {})
        model_id = body.get("model")

        if chat_id not in self.model_names:
            self.model_names[chat_id] = {"id": model_id}
        else:
            self.model_names[chat_id]["id"] = model_id

        if isinstance(model_info, dict) and "name" in model_info:
            self.model_names[chat_id]["name"] = model_info["name"]
            self.log(f"Stored model info - name: '{model_info['name']}', id: '{model_id}' for chat_id: {chat_id}")

        required_keys = ["model", "messages"]
        missing_keys = [key for key in required_keys if key not in body]
        if missing_keys:
            error_message = f"Error: Missing keys in the request body: {', '.join(missing_keys)}"
            self.log(error_message)
            raise ValueError(error_message)

        user_email = user.get("email") if user else None
        task_name = metadata.get("task", "user_response")

        tags_list = self._build_tags(task_name)

        if chat_id not in self.chat_traces:
            self.log(f"Creating new trace for chat_id: {chat_id}")

            try:
                trace_metadata = {
                    **metadata,
                    "user_id": user_email,
                    "session_id": chat_id,
                    "interface": "open-webui",
                }

                trace = self.langfuse.start_span(
                    name=f"chat:{chat_id}",
                    input=body,
                    metadata=trace_metadata
                )

                trace.update_trace(
                    user_id=user_email,
                    session_id=chat_id,
                    tags=tags_list if tags_list else None,
                    input=body,
                    metadata=trace_metadata,
                )

                self.chat_traces[chat_id] = trace
                self.log(f"Successfully created trace for chat_id: {chat_id}")
            except Exception as e:
                self.log(f"Failed to create trace: {e}")
                return body
        else:
            trace = self.chat_traces[chat_id]
            self.log(f"Reusing existing trace for chat_id: {chat_id}")
            trace_metadata = {
                **metadata,
                "user_id": user_email,
                "session_id": chat_id,
                "interface": "open-webui",
            }
            trace.update_trace(
                tags=tags_list if tags_list else None,
                metadata=trace_metadata,
            )

        metadata["type"] = task_name
        metadata["interface"] = "open-webui"

        try:
            trace = self.chat_traces[chat_id]

            event_metadata = {
                **metadata,
                "type": "user_input",
                "interface": "open-webui",
                "user_id": user_email,
                "session_id": chat_id,
                "event_id": str(uuid.uuid4()),
            }

            event_span = trace.start_span(
                name=f"user_input:{str(uuid.uuid4())}",
                metadata=event_metadata,
                input=body["messages"],
            )
            event_span.end()
            self.log(f"User input event logged for chat_id: {chat_id}")
        except Exception as e:
            self.log(f"Failed to log user input event: {e}")

        return body

    async def outlet(self, body: dict, user: Optional[dict] = None) -> dict:
        self.log("Langfuse Filter OUTLET called")

        if not self.langfuse:
            self.log("[WARNING] Langfuse client not initialized - Skipped")
            return body

        self.log(f"Outlet function called with body: {body}")

        chat_id = body.get("chat_id")

        if chat_id == "local":
            session_id = body.get("session_id")
            chat_id = f"temporary-session-{session_id}"

        metadata = body.get("metadata", {})
        task_name = metadata.get("task", "llm_response")

        tags_list = self._build_tags(task_name)

        if chat_id not in self.chat_traces:
            self.log(f"[WARNING] No matching trace found for chat_id: {chat_id}, attempting to re-register.")
            return await self.inlet(body, user)

        self.chat_traces[chat_id]

        assistant_message = get_last_assistant_message(body["messages"])
        assistant_message_obj = get_last_assistant_message_obj(body["messages"])

        usage = None
        if assistant_message_obj:
            info = assistant_message_obj.get("usage", {})
            if isinstance(info, dict):
                input_tokens = info.get("prompt_eval_count") or info.get("prompt_tokens")
                output_tokens = info.get("eval_count") or info.get("completion_tokens")
                if input_tokens is not None and output_tokens is not None:
                    usage = {
                        "input": input_tokens,
                        "output": output_tokens,
                        "unit": "TOKENS",
                    }
                    self.log(f"Usage data extracted: {usage}")

        trace = self.chat_traces[chat_id]

        metadata["type"] = task_name
        metadata["interface"] = "open-webui"

        complete_trace_metadata = {
            **metadata,
            "user_id": user.get("email") if user else None,
            "session_id": chat_id,
            "interface": "open-webui",
            "task": task_name,
        }

        trace.update_trace(
            output=assistant_message,
            metadata=complete_trace_metadata,
            tags=tags_list if tags_list else None,
        )

        model_id = self.model_names.get(chat_id, {}).get("id", body.get("model"))
        model_name = self.model_names.get(chat_id, {}).get("name", "unknown")

        model_value = (
            model_name
            if self.valves.use_model_name_instead_of_id_for_generation
            else model_id
        )

        metadata["model_id"] = model_id
        metadata["model_name"] = model_name

        try:
            trace = self.chat_traces[chat_id]

            generation_metadata = {
                **complete_trace_metadata,
                "type": "llm_response",
                "model_id": model_id,
                "model_name": model_name,
                "generation_id": str(uuid.uuid4()),
            }

            generation = trace.start_generation(
                name=f"llm_response:{str(uuid.uuid4())}",
                model=model_value,
                input=body["messages"],
                output=assistant_message,
                metadata=generation_metadata,
            )

            if usage:
                generation.update(usage=usage)

            generation.end()
            self.log(f"LLM generation completed for chat_id: {chat_id}")
        except Exception as e:
            self.log(f"Failed to create LLM generation: {e}")

        try:
            if self.langfuse:
                self.langfuse.flush()
                self.log("Langfuse data flushed")
        except Exception as e:
            self.log(f"Failed to flush Langfuse data: {e}")

        return body
