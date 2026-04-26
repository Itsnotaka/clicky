/**
 * Clicky transcription token worker.
 *
 * The macOS app uses local Codex for responses and native macOS speech for audio
 * output. The worker only mints short-lived AssemblyAI websocket tokens so the
 * AssemblyAI API key never ships in the app bundle.
 */

interface Env {
  ASSEMBLYAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    if (url.pathname !== "/transcribe-token") {
      return new Response("Not found", { status: 404 });
    }

    try {
      return await handleTranscribeToken(env);
    } catch (error) {
      console.error("[/transcribe-token] Unhandled error:", error);
      return new Response(JSON.stringify({ error: String(error) }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }
  },
};

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
