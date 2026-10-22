# MiniRecorder

MiniRecorder is a small macOS menu bar app that records a meeting and transcribes it on the Mac. It copies the core of the Narada meeting recorder. The design is in `narada-report.md`, section "Proposal: a small working version", in the `rea-work` folder.

The app records two separate tracks:

- `system.caf`: everything that the Mac plays, through a Core Audio process tap. A process tap is a macOS 14.4 API that captures the audio output of processes.
- `mic.caf`: the default microphone, through an `AVAudioEngine` input tap with 4,096-frame buffers.

When you click Stop, the app transcribes both tracks with FluidAudio and Parakeet TDT v3. It labels the mic track "Me" and the system track "Others". Then it orders the lines by time, saves `transcript.txt`, and copies the transcript to the clipboard.

## Requirements

- macOS 14.4 or later, on Apple silicon.
- The Xcode Command Line Tools with Swift 6.1 or later. Xcode is not necessary.
- About 500 MB of disk space for the speech model. The first transcription downloads it from Hugging Face into `~/Library/Application Support/FluidAudio/Models`.

## Build

Run this command from the project folder:

```sh
./scripts/build-app.sh
```

The script builds a release binary with SwiftPM and puts it into `build/MiniRecorder.app`. Then it signs the bundle. The default signature is ad-hoc. To use a certificate, set `SIGN_IDENTITY`, for example `SIGN_IDENTITY="Apple Development: Name (TEAMID)"`.

To run the unit tests, run `swift test`.

## Run

1. Start the app with `open build/MiniRecorder.app`. A microphone icon appears in the menu bar.
2. Click the icon, then click "Request Permissions".
3. Click Allow on the microphone prompt and on the system audio prompt.
4. Click "Start Recording". The icon turns red, and the recording time appears next to it.
5. Click "Stop and Transcribe". When the transcript is ready, the app plays a sound.
6. Paste the transcript into any app.

If no system audio prompt appears, open System Settings > Privacy & Security > Screen & System Audio Recording. Then turn on MiniRecorder under "System Audio Recording Only". Without this permission, the system track is silent. The menu then shows a note.

Always start the app with `open`. If you start the binary in `Contents/MacOS` directly, macOS gives the permissions to the terminal instead of to the app.

The permissions belong to the signature of the bundle. With an ad-hoc signature, each rebuild makes a new signature, and macOS can ask again. To remove the old microphone entry, run `tccutil reset Microphone local.minirecorder.MiniRecorder`. To remove the old system audio entry, use the System Settings page above.

Use headphones. With speakers, the mic also records the other people, and their words appear twice: once as "Me" and once as "Others".

## Dashboard

To see all recordings, click the menu bar icon, then click "Open Dashboard" (Command-D while the menu is open).

- The left column lists the recordings, newest first, with the title or the start time, the length, the tags and the first transcript line.
- The search field shows only the recordings whose title, tags or transcript contain the text.
- The tag menu in the toolbar shows only the recordings with one tag. A click on a tag in the header does the same.
- The right column shows the transcript of the selected recording. "Me" is blue and "Others" is orange.
- To rename a recording, double-click its title, or click the pencil button. You can also use More > Rename or the right-click menu in the left column. An empty title shows the date again.
- To add a tag, click Add Tag, then select a tag that is in use, or click New Tag. To add several new tags at once, separate them with commas. To remove a tag, click the x on it. The right-click menu in the left column also turns tags on and off.
- Copy puts the transcript on the clipboard. Show in Finder opens the meeting folder.
- More > Transcribe Again runs the transcription again, for example after a failure.
- More > Move to Trash moves the meeting folder to the Trash.
- The bar at the bottom plays the mic track and the system track together. To play from a line, click the line. The line that plays has a highlight.
- To copy one line, right-click it, then click Copy Line.
- The Record button in the toolbar starts and stops a recording, as the menu does.

The dashboard plays audio from the app itself. The system tap leaves out the sound of the app, so playback during a recording does not go into the new "Others" track.

## Output

Each recording gets its own folder, named after its start time:

```
~/MiniRecorder/2026-10-22_16-32-34/
  mic.caf          microphone, Float32 at the device rate
  system.caf       system audio, stereo Float32 at the output device rate
  session.json     start and stop time, track offsets, peak levels
  meeting.json     title and tags from the dashboard (only after you add them)
  mic.txt          raw text of the mic track
  system.txt       raw text of the system track
  transcript.txt   merged transcript
```

The transcript lines look like this:

```
[00:02] Others: Good morning, this is Daniel from the design team.
[00:15] Me: Yeah, what else?
```

The app starts a new line at the end of a sentence or after a pause of one second. The two tracks start a few milliseconds apart. `session.json` stores that offset, and the merge step adds it to each track.

The app writes a log to `~/MiniRecorder/minirecorder.log`.

## Command-line options

These options help you test the app:

- `MiniRecorder --transcribe <folder>` transcribes the `mic.caf` and `system.caf` files of an existing folder without the UI. It writes the text files and prints the transcript. You can run the binary in `build/MiniRecorder.app/Contents/MacOS` directly for this option, because it does not record.
- `open build/MiniRecorder.app --args --record-seconds 30` starts the app, records once for 30 seconds, and then transcribes.
- `open build/MiniRecorder.app --args --dashboard` starts the app and opens the dashboard.

## Claude Desktop access (optional)

`mcp/server.py` is a read-only MCP server for the transcripts. MCP (Model Context Protocol) lets an AI client call tools in a local server. The server has three tools:

- `list_meetings`: the meeting folders that have a transcript, newest first, with their titles and tags. With the `tag` argument, only the meetings with that tag.
- `get_transcript`: the full transcript of one meeting.
- `search`: the transcript lines that contain a text, with their meeting and its title.

The folder name stays the same when you rename a recording in the app, so a meeting keeps its name in these tools.

The script declares its dependency in its header, so `uv` installs it. It pins `mcp<2`, because mcp 2.x renamed `FastMCP` to `MCPServer`. To read another folder, set the `MINIRECORDER_ROOT` environment variable.

To add the server to Claude Desktop, add this entry to `~/Library/Application Support/Claude/claude_desktop_config.json`. Replace the path with the location of this project. Then restart Claude Desktop.

```json
{
  "mcpServers": {
    "mini-recorder": {
      "command": "/opt/homebrew/bin/uv",
      "args": ["run", "--script", "/path/to/project/mcp/server.py"]
    }
  }
}
```

Claude Desktop does not use your shell `PATH`, so the entry gives the full path of `uv`. To find it, run `which uv`.

## Known limits

- The system recorder writes the file on the real-time audio thread. This is acceptable for a prototype only. Narada uses `ExtAudioFileWriteAsync`.
- The app does not remove echo. Narada removes it after the call.
- If the output device changes or disconnects during a recording, the system track stops. Narada starts a new part of the recording in that case.
- The transcript has no diarization. Diarization splits the audio by speaker. All remote voices are "Others".
- FluidAudio cuts long audio into chunks. At a chunk boundary, a word can appear twice, for example "Thanks.ks.".
- The app does not paste at the cursor. That feature needs the Accessibility permission. See the report for the cost.
