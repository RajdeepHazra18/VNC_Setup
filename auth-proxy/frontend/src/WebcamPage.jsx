import { useEffect, useRef, useState } from "react";
import "./WebcamPage.css";

// Resolves once ICE candidate gathering finishes (or after `timeoutMs`), so the offer
// we send already lists our network addresses; we don't trickle candidates separately.
function waitForIceGathering(pc, timeoutMs = 2000) {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => {
      pc.removeEventListener("icegatheringstatechange", onChange);
      clearTimeout(timer);
      resolve();
    };
    const onChange = () => {
      if (pc.iceGatheringState === "complete") done();
    };
    const timer = setTimeout(done, timeoutMs);
    pc.addEventListener("icegatheringstatechange", onChange);
  });
}

export default function WebcamPage() {
  const [status, setStatus] = useState("idle");
  const [error, setError] = useState("");
  const [previewReady, setPreviewReady] = useState(false);
  const previewTimerRef = useRef(null);
  const disconnectTimerRef = useRef(null);
  const videoRef = useRef(null);
  const pcRef = useRef(null);
  const streamRef = useRef(null);

  function stopCamera() {
    clearTimeout(previewTimerRef.current);
    clearTimeout(disconnectTimerRef.current);
    setPreviewReady(false);
    if (pcRef.current) {
      pcRef.current.onconnectionstatechange = null;
      pcRef.current.close();
      pcRef.current = null;
    }
    if (streamRef.current) {
      streamRef.current.getTracks().forEach((track) => track.stop());
      streamRef.current = null;
    }
    if (videoRef.current) {
      videoRef.current.srcObject = null;
    }
  }

  function fail(message) {
    stopCamera();
    setError(message);
    setStatus("error");
  }

  async function startCamera() {
    setError("");
    setStatus("connecting");

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        // 640x480 matches what the server scales to (WEBCAM_SIZE); more would be wasted.
        video: { width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 30 } },
        audio: false,
      });
      streamRef.current = stream;
      videoRef.current.srcObject = stream;

      // No STUN servers: the server is reached directly on the local network.
      const pc = new RTCPeerConnection({ iceServers: [] });
      pcRef.current = pc;
      stream.getTracks().forEach((track) => pc.addTrack(track, stream));

      pc.onconnectionstatechange = () => {
        if (pc.connectionState === "connected") {
          // A brief network hiccup can bounce disconnected -> connected on its own;
          // cancel any pending "give up" from a previous disconnect.
          clearTimeout(disconnectTimerRef.current);
          setStatus("streaming");
          setError("");
          // Open the server-side preview only after video is flowing into the
          // virtual camera; a reader opening it first can make ffmpeg's write fail.
          previewTimerRef.current = setTimeout(() => setPreviewReady(true), 2000);
        } else if (pc.connectionState === "failed") {
          fail(
            "WebRTC connection failed. Check that UDP ports 50000-50009 are open on the server."
          );
        } else if (pc.connectionState === "disconnected") {
          // "disconnected" is often transient (a dropped packet, brief Wi-Fi hiccup,
          // NAT rebinding) and can recover to "connected" by itself within a few
          // seconds. Only give up if it hasn't recovered after a grace period.
          setStatus("reconnecting");
          disconnectTimerRef.current = setTimeout(() => {
            if (pcRef.current && pcRef.current.connectionState !== "connected") {
              fail("Connection to the server was lost and did not recover.");
            }
          }, 8000);
        } else if (pc.connectionState === "closed") {
          fail("Connection to the server closed.");
        }
      };

      await pc.setLocalDescription(await pc.createOffer());
      await waitForIceGathering(pc);

      const response = await fetch("/api/webcam/offer", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sdp: pc.localDescription.sdp,
          type: pc.localDescription.type,
        }),
      });
      if (!response.ok) {
        throw new Error(`Server rejected the camera offer (${response.status}).`);
      }
      await pc.setRemoteDescription(await response.json());
    } catch (err) {
      fail(err && err.message ? err.message : "Could not access the camera.");
    }
  }

  function handleStop() {
    stopCamera();
    setStatus("idle");
  }

  useEffect(() => stopCamera, []);

  const streaming = status === "streaming" || status === "reconnecting";

  return (
    <div className="webcam-page">
      <div className="webcam-card">
        <h1>Webcam</h1>
        <p className="webcam-subtitle">
          Stream this computer's camera to the remote desktop's virtual camera (WebRTC).
        </p>

        <div className="webcam-panels">
          <figure>
            <video ref={videoRef} autoPlay muted playsInline />
            <figcaption>Your camera (local)</figcaption>
          </figure>
          <figure>
            {streaming && previewReady ? (
              <img src="/api/webcam/preview" alt="Received by server" />
            ) : (
              <div className="webcam-placeholder">
                {status === "reconnecting"
                  ? "Reconnecting..."
                  : streaming
                  ? "Waiting for server..."
                  : "Not streaming"}
              </div>
            )}
            <figcaption>Received by server</figcaption>
          </figure>
        </div>

        {error && <p className="webcam-error">{error}</p>}
        <p className="webcam-status">Status: {status}</p>

        {streaming ? (
          <button type="button" onClick={handleStop}>
            Stop camera
          </button>
        ) : (
          <button type="button" onClick={startCamera} disabled={status === "connecting"}>
            {status === "connecting" ? "Starting..." : "Start camera"}
          </button>
        )}
      </div>
    </div>
  );
}
