"""
workers/src/aivideo_workers/resolve_adapter.py — DaVinci Resolve Scripting Adapter for AIVideo v3.1 (Gate G0)

Complies strictly with DaVinci Resolve Studio 21.2.0.5 Scripting API:
- Preflight write permissions on export target before project creation
- Unique test project identification to protect user data
- Strict FPS parsing (fails if missing or invalid, never defaults)
- Vertical Timeline: 2160x3840 @ 24.0 fps configured before media append
- Setting verification via GetSetting
- Precise 10-second duration: EXACTLY 240 frames at 24.0 fps (strictly rejects any other duration)
- Parallel video and audio track placement with item duration verification
- Real title insertion verification into timeline
- Project save verification (checks return value)
- Atomic DRP export: exports to temporary file on same filesystem, verifies size, replaces atomically;
  preserves existing DRP on failure
- Returns measured metrics without synthetic pass labels
"""

import os
import sys
import subprocess
import json
import time
import uuid
import shutil
from typing import Dict, Any, Optional, Tuple

RESOLVE_SCRIPTING_MODULE_PATH = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"

def get_resolve():
    """Attempt to connect to a running DaVinci Resolve Studio instance."""
    if RESOLVE_SCRIPTING_MODULE_PATH not in sys.path:
        sys.path.append(RESOLVE_SCRIPTING_MODULE_PATH)
    try:
        import DaVinciResolveScript as dvr
        return dvr.scriptapp("Resolve")
    except Exception as exc:
        from .diagnostics import note_suppressed
        note_suppressed("resolve_adapter.py:37", exc)
        return None

def check_resolve_status() -> dict:
    resolve = get_resolve()
    if not resolve:
        return {
            "running": False,
            "connected": False,
            "product_name": None,
            "version": None,
            "error": "DaVinci Resolve is not running or scripting API is unreachable."
        }
    return {
        "running": True,
        "connected": True,
        "product_name": resolve.GetProductName(),
        "version": resolve.GetVersionString(),
        "error": None
    }

def create_synthetic_test_assets(target_dir: str) -> Tuple[str, str]:
    """Generates exactly 10.0 seconds (240 frames @ 24 fps) synthetic video & audio test assets with process supervision."""
    os.makedirs(target_dir, exist_ok=True)
    video_path = os.path.join(target_dir, "test_clip_10s_24fps.mp4")
    audio_path = os.path.join(target_dir, "test_voice_10s_48k.wav")

    ffmpeg_bin = "/opt/homebrew/bin/ffmpeg"
    if not os.path.exists(ffmpeg_bin):
        ffmpeg_bin = shutil.which("ffmpeg") or "ffmpeg"

    def run_ffmpeg_supervised(cmd: list, timeout: float = 30.0):
        try:
            from main import register_child_pid, unregister_child_pid
        except ImportError:
            register_child_pid = None
            unregister_child_pid = None

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True
        )
        if register_child_pid:
            register_child_pid(proc.pid)
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
            if proc.returncode != 0:
                raise RuntimeError(f"FFmpeg fixture generation failed (exit {proc.returncode}): {stderr.strip()}")
            return stdout, stderr
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, 9)
            except OSError:
                proc.kill()
            stdout, stderr = proc.communicate()
            raise TimeoutError(f"FFmpeg command timed out after {timeout}s: {' '.join(cmd[:4])}")
        finally:
            if unregister_child_pid:
                unregister_child_pid(proc.pid)

    # Exactly 240 frames (10 seconds at 24fps) with parallel synchronous audio
    cmd_video = [
        ffmpeg_bin, "-y",
        "-f", "lavfi", "-i", "testsrc=duration=10:size=1080x1920:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
        "-c:v", "libx264", "-c:a", "aac", "-pix_fmt", "yuv420p",
        video_path
    ]
    run_ffmpeg_supervised(cmd_video, timeout=30.0)

    # Standalone 10.0s 48kHz audio tone
    cmd_audio = [
        ffmpeg_bin, "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
        "-ar", "48000", "-ac", "2",
        audio_path
    ]
    run_ffmpeg_supervised(cmd_audio, timeout=30.0)

    return video_path, audio_path

def run_g0_spike(output_drp_path: str = "fixtures/AIVideo_G0_Spike.drp", force_fresh_run: bool = False) -> dict:
    """
    Executes Gate G0 10-second timeline spike in DaVinci Resolve.
    Postconditions verified:
    - Connected to Resolve Studio
    - Output directory preflight verified writable
    - Unique project created (no user projects overwritten)
    - Timeline resolution: 2160x3840 @ 24.0 fps
    - Duration: EXACTLY 240 frames (any deviation rejected)
    - Item durations verified on video and audio tracks
    - Title inserted and verified
    - Render configured and project saved
    - Atomic DRP export with preservation of previous file on failure
    """
    # 0. Preflight export directory
    abs_drp_path = os.path.abspath(output_drp_path)
    export_dir = os.path.dirname(abs_drp_path)
    os.makedirs(export_dir, exist_ok=True)
    if not os.access(export_dir, os.W_OK):
        raise PermissionError(f"Export directory is not writable: {export_dir}")

    resolve = get_resolve()
    if not resolve:
        raise RuntimeError("DaVinci Resolve Studio is not running. Please launch DaVinci Resolve first.")

    pm = resolve.GetProjectManager()
    if not pm:
        raise RuntimeError("Failed to obtain Resolve ProjectManager from Resolve scripting API.")

    run_uuid = str(uuid.uuid4())[:8]
    project_name = f"AIVideo_G0_Spike_{run_uuid}"

    # Handle force_fresh_run: close current project if needed
    if force_fresh_run:
        try:
            curr_proj = pm.GetCurrentProject()
            if curr_proj and curr_proj.GetName().startswith("AIVideo_G0_Spike_"):
                pm.CloseProject(curr_proj)
        except Exception as exc:
            from .diagnostics import note_suppressed
            note_suppressed("resolve_adapter.py:159", exc)
            pass

    # 1. Create unique project
    proj = pm.CreateProject(project_name)
    if not proj:
        raise RuntimeError(f"Failed to create unique test project: '{project_name}'.")

    # Run-isolated fixture assets directory
    run_fixtures_dir = os.path.abspath(f"fixtures/g0_spike_assets/run_{run_uuid}")
    video_path, audio_path = create_synthetic_test_assets(run_fixtures_dir)

    # 2. Setup MediaPool and import media
    mp = proj.GetMediaPool()
    if not mp:
        raise RuntimeError("Failed to access MediaPool in test project.")

    imported_items = mp.ImportMedia([video_path, audio_path])
    if not imported_items or len(imported_items) < 1:
        raise RuntimeError(f"MediaPool.ImportMedia failed to import test clips: video={video_path}, audio={audio_path}")

    # 3. Create Timeline & Configure Settings BEFORE appending clips
    timeline_name = f"Timeline_10s_Vertical_{run_uuid}"
    tl = mp.CreateEmptyTimeline(timeline_name)
    if not tl:
        raise RuntimeError(f"Failed to create empty timeline: '{timeline_name}'")

    # Add Track V2 for Title overlay
    tl.AddTrack("video")

    # Set Custom Settings: Vertical 2160x3840 @ 24 fps
    tl.SetSetting("useCustomSettings", "1")
    tl.SetSetting("timelineResolutionWidth", "2160")
    tl.SetSetting("timelineResolutionHeight", "3840")
    tl.SetSetting("timelineFrameRate", "24")

    # Read back settings to prove actual configuration (no blind trust)
    actual_width_raw = tl.GetSetting("timelineResolutionWidth")
    actual_height_raw = tl.GetSetting("timelineResolutionHeight")
    actual_fps_raw = tl.GetSetting("timelineFrameRate")

    if actual_width_raw is None or actual_height_raw is None or actual_fps_raw is None:
        raise RuntimeError("Failed to retrieve timeline resolution or frame rate settings from Resolve engine.")

    actual_width = str(actual_width_raw).strip()
    actual_height = str(actual_height_raw).strip()

    try:
        actual_fps = float(str(actual_fps_raw).strip())
    except (ValueError, TypeError) as err:
        raise RuntimeError(f"Could not parse timelineFrameRate '{actual_fps_raw}': {err}")

    if actual_width != "2160" or actual_height != "3840" or actual_fps != 24.0:
        raise RuntimeError(f"Timeline settings verification failed! Expected 2160x3840 @ 24.0fps, observed {actual_width}x{actual_height} @ {actual_fps}fps.")

    # 4. Append Media Clips to Timeline with explicit track and recordFrame mapping
    # Exactly 240 frames on timeline from recordFrame 86400 (SMPTE 01:00:00:00)
    target_clip = imported_items[0]
    clip_info_v = {
        "mediaPoolItem": target_clip,
        "startFrame": 0,
        "endFrame": 240,
        "mediaType": 1, # 1 - Video only
        "trackIndex": 1,
        "recordFrame": 86400
    }
    clip_info_a = {
        "mediaPoolItem": target_clip,
        "startFrame": 0,
        "endFrame": 240,
        "mediaType": 2, # 2 - Audio only
        "trackIndex": 1,
        "recordFrame": 86400
    }

    append_result = mp.AppendToTimeline([clip_info_v, clip_info_a])
    if not append_result or len(append_result) < 2:
        raise RuntimeError("mp.AppendToTimeline returned False or insufficient items for mapped video and audio.")

    # 5. Insert Title and Move to Track V2 overlaid from start frame 86400
    title_inserted = False
    title_item = tl.InsertFusionTitleIntoTimeline("Text+")
    if title_item is None:
        title_item = tl.InsertTitleIntoTimeline("Text")

    if title_item is not None:
        # Move title to Track 2, startFrame 86400 (overlay within 240 frames, not extending timeline)
        moved = tl.MoveItems([title_item], {"trackIndex": 2, "startFrame": 86400})
        if moved:
            title_inserted = True

    if not title_inserted:
        raise RuntimeError(
            "Resolve title insertion or placement failed."
        )

    title_track_items = (
        tl.GetItemListInTrack("video", 2) or []
    )

    if not title_track_items:
        raise RuntimeError(
            "Title was not found on Video Track 2."
        )

    # 6. Verify Frame Duration: MUST be EXACTLY 240 frames (10 seconds @ 24fps)
    start_frame = tl.GetStartFrame()
    end_frame = tl.GetEndFrame()

    if start_frame is None or end_frame is None:
        raise RuntimeError("Could not retrieve start frame or end frame from Resolve timeline.")

    total_frames = end_frame - start_frame

    if total_frames != 240:
        raise RuntimeError(
            f"Frame boundary check FAILED: Timeline duration is {total_frames} frames "
            f"(start: {start_frame}, end: {end_frame}). Expected EXACTLY 240 frames for 10.0s @ 24fps."
        )

    track_count_v = tl.GetTrackCount("video")
    track_count_a = tl.GetTrackCount("audio")
    video_items = tl.GetItemListInTrack("video", 1) or []
    audio_items = tl.GetItemListInTrack("audio", 1) or []

    if len(video_items) < 1:
        raise RuntimeError("No video clip found on Video Track 1.")
    if len(audio_items) < 1:
        raise RuntimeError("No audio clip found on Audio Track 1.")

    # Read back individual item durations
    v_item = video_items[0]
    a_item = audio_items[0]
    v_duration = v_item.GetDuration()
    a_duration = a_item.GetDuration()

    if v_duration != 240 or a_duration != 240:
        raise RuntimeError(f"Track item duration mismatch: video={v_duration} frames, audio={a_duration} frames (expected 240 frames).")

    # 7. Render Configuration Setup
    render_codecs_mp4 = proj.GetRenderCodecs("mp4") or {}
    supported_codecs = list(render_codecs_mp4.keys()) if isinstance(render_codecs_mp4, dict) else list(render_codecs_mp4)

    if not supported_codecs:
        raise RuntimeError("No valid MP4 render codecs available in Resolve for target profile.")

    render_out_dir = os.path.abspath("fixtures/renders")
    os.makedirs(render_out_dir, exist_ok=True)
    preview_name = f"preview_{run_uuid}"

    render_settings_ok = proj.SetRenderSettings({
        "SelectAllFrames": True,
        "TargetDir": render_out_dir,
        "CustomName": preview_name,
        "FormatWidth": 1080,
        "FormatHeight": 1920,
        "FrameRate": 24.0,
        "ExportVideo": True,
        "ExportAudio": True
    })

    if render_settings_ok is not True:
        raise RuntimeError(
            "Resolve SetRenderSettings failed."
        )

    # 8. Save Project & Verify Return Value & Reopening
    save_ok = pm.SaveProject()
    if not save_ok:
        raise RuntimeError("Resolve ProjectManager.SaveProject() returned False.")

    reopened_proj = pm.LoadProject(project_name)
    if not reopened_proj:
        raise RuntimeError(f"Failed to reopen/verify saved project '{project_name}'.")

    # 9. Atomic DRP Export (Preserves old DRP on failure)
    tmp_drp_path = f"{abs_drp_path}.tmp_{run_uuid}.drp"
    if os.path.exists(tmp_drp_path):
        os.remove(tmp_drp_path)

    export_drp_ok = pm.ExportProject(project_name, tmp_drp_path)
    if not export_drp_ok or not os.path.exists(tmp_drp_path) or os.path.getsize(tmp_drp_path) < 1024:
        if os.path.exists(tmp_drp_path):
            try:
                os.remove(tmp_drp_path)
            except OSError:
                pass
        raise RuntimeError(f"Failed to export Resolve project archive to temporary path '{tmp_drp_path}'. Existing DRP preserved.")

    import zipfile
    if not zipfile.is_zipfile(tmp_drp_path):
        if os.path.exists(tmp_drp_path):
            try:
                os.remove(tmp_drp_path)
            except OSError:
                pass
        raise RuntimeError(f"Exported DRP is not a valid zip archive: '{tmp_drp_path}'.")

    with zipfile.ZipFile(tmp_drp_path, "r") as zf:
        if not zf.namelist():
            if os.path.exists(tmp_drp_path):
                try:
                    os.remove(tmp_drp_path)
                except OSError:
                    pass
            raise RuntimeError(f"Exported DRP zip archive is empty: '{tmp_drp_path}'.")

    # Atomically replace final DRP
    os.replace(tmp_drp_path, abs_drp_path)
    final_drp_size = os.path.getsize(abs_drp_path)

    return {
        "success": True,
        "resolve_product": resolve.GetProductName(),
        "resolve_version": resolve.GetVersionString(),
        "project_name": project_name,
        "timeline_name": timeline_name,
        "timeline_resolution": f"{actual_width}x{actual_height}",
        "timeline_fps": actual_fps,
        "timeline_start_frame": start_frame,
        "timeline_end_frame": end_frame,
        "timeline_total_frames": total_frames,
        "video_track_count": track_count_v,
        "audio_track_count": track_count_a,
        "video_items_count": len(video_items),
        "audio_items_count": len(audio_items),
        "video_item_duration": v_duration,
        "audio_item_duration": a_duration,
        "title_inserted": title_inserted,
        "render_settings_configured": bool(render_settings_ok),
        "project_saved": bool(save_ok),
        "preview_path": None,
        "drp_exported": True,
        "drp_path": abs_drp_path,
        "drp_size_bytes": final_drp_size,
        "supported_mp4_codecs": supported_codecs,
        "verified_steps": [
            "resolve_connection",
            "preflight_permissions",
            "unique_project_created",
            "timeline_settings_configured",
            "media_imported",
            "media_appended_parallel",
            "frame_boundary_240_verified",
            "title_inserted",
            "title_verified_track_2",
            "render_settings_configured",
            "project_saved",
            "project_reopened_verified",
            "atomic_drp_exported",
            "drp_zip_archive_verified"
        ]
    }

if __name__ == "__main__":
    status = check_resolve_status()
    print("Resolve Status:", json.dumps(status, indent=2))
