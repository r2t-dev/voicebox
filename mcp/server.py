# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]  # mcp 2.x renamed FastMCP to MCPServer.
# ///
"""Read-only MCP server for the MiniRecorder transcripts in ~/MiniRecorder."""

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


def _info(path: Path) -> dict:
    """The title and tags that the user gave in the app (meeting.json)."""
    try:
        data = json.loads((path / "meeting.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    return {"title": data.get("title"), "tags": data.get("tags", [])}


@mcp.tool()
def list_meetings(tag: str | None = None) -> list[dict]:
    """All recorded meetings that have a transcript, newest first.

    Each item has the meeting name, which is the start time of the recording
    (for example 2026-10-22_16-30-05) and the argument for get_transcript, plus the
    title and the tags that the user gave in the app. With `tag`, only the meetings
    with that tag (case-insensitive).
    """
    meetings = [{"meeting": p.name, **_info(p)} for p in _meeting_dirs()]
    if tag:
        meetings = [m for m in meetings if tag.lower() in (t.lower() for t in m["tags"])]
    return meetings


@mcp.tool()
def get_transcript(meeting: str) -> str:
    """Full transcript of one meeting. Lines look like "[mm:ss] Me: text" or "[mm:ss] Others: text"."""
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
