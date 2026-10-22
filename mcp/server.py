# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2,<2"]  # mcp 2.x renamed FastMCP to MCPServer.
# ///
"""Read-only MCP server for the MiniRecorder transcripts in ~/MiniRecorder."""

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


@mcp.tool()
def list_meetings() -> list[str]:
    """Names of all recorded meetings that have a transcript, newest first.

    A name is the start time of the recording, for example 2026-10-22_16-30-05.
    """
    return [p.name for p in _meeting_dirs()]


@mcp.tool()
def get_transcript(meeting: str) -> str:
    """Full transcript of one meeting. Lines look like "[mm:ss] Me: text" or "[mm:ss] Others: text"."""
    return (_meeting_dir(meeting) / "transcript.txt").read_text(encoding="utf-8")


@mcp.tool()
def search(text: str, limit: int = 50) -> list[dict]:
    """Transcript lines that contain the text (case-insensitive), with their meeting, newest meeting first."""
    needle = text.lower()
    hits = []
    for path in _meeting_dirs():
        for line in (path / "transcript.txt").read_text(encoding="utf-8").splitlines():
            if needle in line.lower():
                hits.append({"meeting": path.name, "line": line})
                if len(hits) >= limit:
                    return hits
    return hits


if __name__ == "__main__":
    mcp.run()
