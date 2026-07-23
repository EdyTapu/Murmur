#!/usr/bin/env python3
"""Murmur gaze helper.

Pure feature extractor: reads raw BGRA camera frames from stdin, runs
MediaPipe FaceLandmarker (478 landmarks incl. iris + head-pose matrix), and
writes one JSON line per frame to stdout. It never opens the camera and never
touches the network - Murmur owns capture, permissions, calibration, and the
cursor.

Usage: gaze_helper.py /path/to/face_landmarker.task

Frame protocol (little-endian), repeated until EOF:
    u32 magic 0x475A4652 ('GZFR')   u32 width   u32 height   u32 bytesPerRow
    then bytesPerRow * height bytes of BGRA pixels.

Output per frame (one line):
    {"face": 1, "f": [10 gaze features], "earL": .., "earR": ..}
    {"face": 0}

Feature vector:
    0-3  iris offset within each eye box:  ixR, iyR, ixL, iyL
         (iris center relative to the eye-corner midpoint, / eye width)
    4-6  head rotation: yaw, pitch, roll (radians, from the pose matrix)
    7-9  head translation: tx, ty, tz (cm, from the pose matrix)
"""

import json
import math
import struct
import sys

import numpy as np

MAGIC = 0x475A4652

# FaceLandmarker landmark indices (iris landmarks are 468-477).
# "Right eye" is the subject's right eye, which appears on the image's left.
R_OUT, R_IN = 33, 133
L_IN, L_OUT = 362, 263
R_IRIS, L_IRIS = 468, 473
# Standard 6-point Eye Aspect Ratio sets (p1..p6).
R_EAR = (33, 160, 158, 133, 153, 144)
L_EAR = (263, 387, 385, 362, 380, 373)


def ear(pts, idx):
    p1, p2, p3, p4, p5, p6 = (pts[i] for i in idx)
    horiz = np.linalg.norm(p1 - p4)
    if horiz < 1e-6:
        return 0.0
    return float((np.linalg.norm(p2 - p6) + np.linalg.norm(p3 - p5)) / (2.0 * horiz))


def iris_offset(pts, corner_a, corner_b, iris):
    center = (pts[corner_a] + pts[corner_b]) / 2.0
    width = np.linalg.norm(pts[corner_a] - pts[corner_b])
    if width < 1e-6:
        return 0.0, 0.0
    off = (pts[iris] - center) / width
    return float(off[0]), float(off[1])


def pose_angles(matrix):
    """Yaw/pitch/roll from the 4x4 facial transformation matrix.

    The exact Euler convention is irrelevant downstream - the calibration
    regression only needs three numbers monotonic in head rotation.
    """
    r = matrix[:3, :3]
    yaw = math.atan2(r[0, 2], r[2, 2])
    pitch = -math.asin(max(-1.0, min(1.0, r[1, 2])))
    roll = math.atan2(r[1, 0], r[1, 1])
    return yaw, pitch, roll


def features(pts, matrix):
    ixr, iyr = iris_offset(pts, R_OUT, R_IN, R_IRIS)
    ixl, iyl = iris_offset(pts, L_IN, L_OUT, L_IRIS)
    yaw, pitch, roll = pose_angles(matrix)
    tx, ty, tz = (float(v) for v in matrix[:3, 3])
    return [ixr, iyr, ixl, iyl, yaw, pitch, roll, tx, ty, tz]


def read_exact(stream, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def main():
    model_path = sys.argv[1]

    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    landmarker = vision.FaceLandmarker.create_from_options(
        vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=model_path),
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
            output_facial_transformation_matrixes=True,
        ))
    stdin = sys.stdin.buffer
    stdout = sys.stdout

    # Handshake so the Swift side can distinguish "helper ready" from
    # "helper died importing mediapipe".
    stdout.write(json.dumps({"ready": 1}) + "\n")
    stdout.flush()

    # VIDEO mode wants monotonically increasing timestamps; frames arrive at
    # ~15 fps, so a fixed 66 ms step keeps the tracker's temporal filter happy
    # without trusting wall-clock jitter.
    timestamp_ms = 0
    while True:
        header = read_exact(stdin, 16)
        if header is None:
            return
        magic, width, height, bpr = struct.unpack("<IIII", header)
        if magic != MAGIC or width == 0 or height == 0 or bpr < width * 4:
            print(json.dumps({"error": "bad frame header"}), file=sys.stderr)
            return
        raw = read_exact(stdin, bpr * height)
        if raw is None:
            return

        bgra = np.frombuffer(raw, dtype=np.uint8).reshape(height, bpr)
        bgra = bgra[:, : width * 4].reshape(height, width, 4)
        rgb = np.ascontiguousarray(bgra[:, :, [2, 1, 0]])

        timestamp_ms += 66
        result = landmarker.detect_for_video(
            mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), timestamp_ms)
        if not result.face_landmarks or not result.facial_transformation_matrixes:
            stdout.write('{"face":0}\n')
            stdout.flush()
            continue

        pts = np.array(
            [(p.x, p.y) for p in result.face_landmarks[0]], dtype=np.float64)
        matrix = np.array(result.facial_transformation_matrixes[0], dtype=np.float64)
        out = {
            "face": 1,
            "f": [round(v, 6) for v in features(pts, matrix)],
            "earL": round(ear(pts, L_EAR), 5),
            "earR": round(ear(pts, R_EAR), 5),
        }
        stdout.write(json.dumps(out) + "\n")
        stdout.flush()


if __name__ == "__main__":
    main()
