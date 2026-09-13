FROM python:3.11-slim

WORKDIR /app

# Hash-checked installation from the generated, locked requirements export.
COPY requirements.txt ./
RUN pip install --no-cache-dir --require-hashes -r requirements.txt

# All backend runtime modules, including the relay.
COPY logging_config.py apns.py relay.py storage.py main.py ./

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
