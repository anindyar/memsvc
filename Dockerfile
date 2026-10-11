FROM python:3.12-slim
RUN pip install --no-cache-dir "mcp[cli]==1.*" "psycopg[binary]==3.*" httpx
COPY memsvc.py /app/memsvc.py
CMD ["python", "/app/memsvc.py"]
