#!/bin/bash

MODEL_NAME=${OLLAMA_MODEL:-mistral}

echo "Starting background Ollama server for initialization..."
/bin/ollama serve &
OLLAMA_PID=$!

echo "Waiting for Ollama API to become available..."
until ollama list > /dev/null 2>&1; do
    sleep 2
done

echo "Checking for model: $MODEL_NAME..."
if ! ollama list | grep -q "$MODEL_NAME"; then
    echo "Model $MODEL_NAME not found. Downloading..."
    ollama pull "$MODEL_NAME"
    echo "Download complete!"
else
    echo "Model $MODEL_NAME is already present."
fi

echo "Ollama is ready. Switching to foreground server..."
kill $OLLAMA_PID
wait
