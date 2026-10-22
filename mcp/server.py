# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]  # mcp 2.x renamed FastMCP to MCPServer.
# ///
"""Read-only MCP server for the Voicebox transcripts in ~/MiniRecorder."""

import json
import os
from pathlib import Path

from mcp.server.fastmcp import FastMCP

ROOT = Path(os.environ.get("MINIRECORDER_ROOT", Path.home() / "MiniRecorder")).expanduser()
mcp = FastMCP("mini-recorder")


def _meeting_dirs() -> list[Path]:
    if not ROOT.is_dir():
        return []
    return sorted((p for p in ROOT.iterdir() if (p / "transcript.txt").is_file()), reverse=True)


def _meeting_dir(meeting: str) -> Path:
    path = ROOT / meeting
    if path.parent != ROOT or not (path / "transcript.txt").is_file():
        raise ValueError(f"No meeting named {meeting!r}. Call list_meetings for the names.")
    return path


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _info(path: Path) -> dict:
    """The kind of recording (session.json) and the title and tags from the app (meeting.json)."""
    info = _read_json(path / "meeting.json")
    return {
        "kind": _read_json(path / "session.json").get("kind") or "meeting",
        "title": info.get("title"),
        "tags": info.get("tags", []),
    }


@mcp.tool()
def list_meetings(tag: str | None = None, kind: str | None = None) -> list[dict]:
    """All recordings that have a transcript, newest first.

    Each item has the meeting name, which is the start time of the recording
    (for example 2026-10-22_16-30-05) and the argument for get_transcript, the kind,
    and the title and tags that the user gave in the app. The kind is "meeting"
    (microphone as "Me", the speakers in the system audio as "Speaker 1", "Speaker 2"
    and so on), "note" (microphone only, speakers labeled the same way) or "voice"
    (dictated text without timestamps). Older transcripts use "Others" for the system
    audio and "Speaker" for every line of a note.
    With `tag` or `kind`, only the matching recordings (case-insensitive).
    """
    meetings = [{"meeting": p.name, **_info(p)} for p in _meeting_dirs()]
    if tag:
        meetings = [m for m in meetings if tag.lower() in (t.lower() for t in m["tags"])]
    if kind:
        meetings = [m for m in meetings if m["kind"] == kind.lower()]
    return meetings


@mcp.tool()
def get_transcript(meeting: str) -> str:
    """Full transcript of one recording.

    Meeting lines look like "[mm:ss] Me: text" or "[mm:ss] Others: text". Note lines look
    like "[mm:ss] Speaker: text". Voice input is plain text.
    """
    return (_meeting_dir(meeting) / "transcript.txt").read_text(encoding="utf-8")


@mcp.tool()
def search(text: str, limit: int = 50) -> list[dict]:
    """Transcript lines that contain the text (case-insensitive), with their meeting and its title, newest meeting first."""
    needle = text.lower()
    hits = []
    for path in _meeting_dirs():
        title = _info(path)["title"]
        for line in (path / "transcript.txt").read_text(encoding="utf-8").splitlines():
            if needle in line.lower():
                hits.append({"meeting": path.name, "title": title, "line": line})
                if len(hits) >= limit:
                    return hits
    return hits


if __name__ == "__main__":
    mcp.run()
