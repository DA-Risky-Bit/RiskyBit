#!/bin/bash

MODEL_NAME=${OLLAMA_MODEL:-mistral}
echo "Starting temporary Ollama server to pull $MODEL_NAME..."
ollama serve &
PID=$!

# Wait for server to respond
until ollama list > /dev/null 2>&1; do
    sleep 2
done

echo "Downloading $MODEL_NAME..."
ollama pull "$MODEL_NAME"

echo "Download complete. Shutting down downloader container."
kill $PID
